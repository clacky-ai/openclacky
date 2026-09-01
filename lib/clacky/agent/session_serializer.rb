# frozen_string_literal: true

require "strscan"

module Clacky
  class Agent
    # Session serialization for saving and restoring agent state
    # Handles session data serialization and deserialization
    module SessionSerializer
      # Restore from a saved session
      # @param session_data [Hash] Saved session data
      def restore_session(session_data)
        @session_id = session_data[:session_id]
        @name = session_data[:name] || ""
        @pinned = session_data[:pinned] || false
        @history = MessageHistory.new(session_data[:messages] || [])
        @todos = session_data[:todos] || []  # Restore todos from session
        @iterations = session_data.dig(:stats, :total_iterations) || 0
        @total_cost = session_data.dig(:stats, :total_cost_usd) || 0.0
        @working_dir = session_data[:working_dir]
        @created_at = session_data[:created_at]
        @persisted_updated_at = session_data[:updated_at]
        @total_tasks = session_data.dig(:stats, :total_tasks) || 0
        # Restore cost_source so frontend knows if cost is reliable
        cost_src = session_data.dig(:stats, :cost_source)
        @cost_source = (cost_src && cost_src.to_sym) || :estimated
        @task_cost_source = :estimated
        # Restore source; fall back to :manual for sessions saved before this field existed
        @source = (session_data[:source] || "manual").to_sym

        # Restore channel info for IM platform sessions
        @channel_info = session_data[:channel_info]

        # Restore project association (nil = no project)
        @project_id = session_data[:project_id]

        # Restore standing goal state (nil = no goal). The judge client/model
        # are rebound lazily via #goal_manager when first accessed after
        # restore — but the persisted state must be reattached here so a
        # restored active goal keeps its progress and continues.
        restore_goal_state(session_data[:goal])

        # Restore cache statistics if available
        @cache_stats = session_data.dig(:stats, :cache_stats) || {
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          total_requests: 0,
          cache_hit_requests: 0
        }

        # Restore previous_total_tokens for accurate delta calculation across sessions
        @previous_total_tokens = session_data.dig(:stats, :previous_total_tokens) || 0

        # Recover the latest latency metric from the most recent assistant message
        # that carries a :latency field. This is the source of truth for the status-bar
        # signal — no separate session-level field is needed. Older sessions (pre-feature)
        # simply start with nil; the signal stays hidden until the next LLM call populates it.
        last_assistant_with_latency = @history.to_a.reverse.find do |m|
          m[:role].to_s == "assistant" && m[:latency]
        end
        @latest_latency = last_assistant_with_latency&.dig(:latency)

        # Restore Time Machine state. JSON.parse(symbolize_names:) turns the
        # task_parents hash keys into symbols like :"1"; the runtime expects
        # Integer keys/values, so coerce both ends back here.
        raw_parents = session_data.dig(:time_machine, :task_parents) || {}
        @task_parents = raw_parents.each_with_object({}) { |(k, v), h| h[k.to_s.to_i] = v.to_i }
        @current_task_id = (session_data.dig(:time_machine, :current_task_id) || 0).to_i
        @active_task_id = (session_data.dig(:time_machine, :active_task_id) || 0).to_i

        raw_meta = session_data.dig(:time_machine, :task_meta) || {}
        @task_meta = raw_meta.each_with_object({}) do |(k, v), h|
          tid = k.to_s.to_i
          attrs = v.is_a?(Hash) ? v : {}
          h[tid] = {
            title:      attrs[:title] || attrs["title"],
            started_at: (attrs[:started_at] || attrs["started_at"])&.to_f,
            ended_at:   (attrs[:ended_at]   || attrs["ended_at"])&.to_f,
          }
        end
        backfill_task_meta_from_history!
        heal_missing_chunk_paths!

        # Check if the session ended with an error.
        # We record the rollback intent here but do NOT truncate history immediately —
        # truncating at restore time causes the history replay to return empty results,
        # leaving the chat panel blank on first open.
        # Instead, the rollback is deferred: history is trimmed lazily when the user
        # actually sends the next message (see run() / handle_user_message).
        last_status = session_data.dig(:stats, :last_status)
        last_error = session_data.dig(:stats, :last_error)

        if last_status == "error" && last_error
          @pending_error_rollback = true
        end

        saved_reasoning = session_data.dig(:config, :reasoning_effort)
        self.reasoning_effort = saved_reasoning if saved_reasoning

        # Restore the session's original model if it still exists in the current
        # config. This prevents all sessions from silently switching to the new
        # default model when the user changes it and restarts. Falls back to the
        # current default if the model was deleted/renamed since the session was
        # last saved.
        saved_model_name = session_data.dig(:config, :model_name)
        if saved_model_name
          saved_base_url = session_data.dig(:config, :model_base_url)
          model_entry = @config.find_model_by_name_and_url(saved_model_name, saved_base_url)
          if model_entry && model_entry["id"]
            switch_model_by_id(model_entry["id"])
          end
        end

        # Re-apply the per-session sub-model pin (if any). Done AFTER
        # switch_model_by_id so the overlay isn't cleared by the card switch
        # invariant. Validation happens at write-time (the WebUI/API enforces
        # the name belongs to the card's provider) — at restore-time we trust
        # what we previously wrote.
        saved_sub_model = session_data.dig(:config, :sub_model)
        if saved_sub_model && !saved_sub_model.to_s.empty?
          set_session_sub_model(saved_sub_model)
        end

        # Rebuild and refresh the system prompt so any newly installed skills
        # (or other configuration changes since the session was saved) are
        # reflected immediately — without requiring the user to create a new session.
        refresh_system_prompt
      end

      # Reattach persisted goal state after a restore. Builds a fresh
      # GoalManager (bound to this agent's judge client/model) and injects the
      # deserialized GoalState so a restored active goal keeps its progress.
      private def restore_goal_state(goal_data)
        return if goal_data.nil? || goal_data.empty?

        state = GoalState.from_h(goal_data)
        @goal_manager = GoalManager.new(
          judge_client: @client,
          judge_model:  judge_model_name,
          state:        state
        )
      rescue => e
        Clacky::Logger.warn("restore_goal_state failed: #{e.message}")
      end

      # Fill missing entries in @task_meta from @history (for sessions saved
      # before task_meta existed, or for tasks whose meta was lost). The first
      # real user message of each task supplies the title; created_at becomes
      # started_at; the latest message in the task supplies ended_at. Tasks
      # whose user turn has already been archived stay without a title and
      # the UI falls back to "Task N".
      private def backfill_task_meta_from_history!
        @task_meta ||= {}
        return if @current_task_id.to_i <= 0

        @history.to_a.each do |m|
          tid = m[:task_id]
          next unless tid.is_a?(Integer) && tid > 0
          next if m[:system_injected]

          entry = (@task_meta[tid] ||= {})
          if m[:role].to_s == "user" && (entry[:title].nil? || entry[:title].to_s.empty?)
            text = extract_text_from_content(m[:content]).to_s.gsub(/\s+/, " ").strip
            entry[:title] = text.length > 60 ? "#{text[0...57]}..." : text unless text.empty?
          end
          ts = m[:created_at]
          next unless ts
          entry[:started_at] ||= ts.to_f
          cur_end = entry[:ended_at]
          entry[:ended_at] = ts.to_f if cur_end.nil? || ts.to_f > cur_end
        end
      end

      # Repair compressed_summary messages whose chunk_path is missing or points
      # at a file that no longer exists. This happens when a hot restart's
      # SIGKILL killed the worker after the chunk file was written to disk but
      # before its path was persisted into session.json — the archived history
      # then never renders on replay. Rediscover the chunk on disk from
      # session_id + created_at and write the real path back, once, at load time.
      private def heal_missing_chunk_paths!
        return unless @session_id && @created_at

        broken = @history.to_a.select do |m|
          m[:compressed_summary] && !(m[:chunk_path] && File.exist?(m[:chunk_path].to_s))
        end
        return if broken.empty?

        chunks = session_manager.chunks_for_current(@session_id, @created_at)
        return if chunks.empty?

        latest_path = chunks.last[:path]
        broken.each { |m| m[:chunk_path] = latest_path }

        session_manager.save(to_session_data)
      rescue => e
        Clacky::Logger.warn("heal_missing_chunk_paths! failed: #{e.message}")
      end

      private def persisted_card_field(key)
        card_id = @config.current_model_id
        return nil unless card_id
        @config.models.find { |m| m["id"] == card_id }&.dig(key)
      end

      # Generate session data for saving
      # @param status [Symbol] Status of the last task: :success, :error, or :interrupted
      # @param error_message [String] Error message if status is :error
      # @return [Hash] Session data ready for serialization
      def to_session_data(status: :success, error_message: nil, raw_message: nil, updated_at: nil)
        stats_data = {
          total_tasks: @total_tasks,
          total_iterations: @iterations,
          total_cost_usd: @total_cost.round(4),
          cost_source: @cost_source.to_s,
          duration_seconds: @start_time ? (Time.now - @start_time).round(2) : 0,
          last_status: status.to_s,
          cache_stats: @cache_stats,
          debug_logs: @debug_logs,
          previous_total_tokens: @previous_total_tokens
        }

        # Add error message if status is error
        stats_data[:last_error]     = error_message if status == :error && error_message
        stats_data[:last_error_raw] = raw_message   if status == :error && raw_message

        {
          session_id: @session_id,
          name: @name,
          pinned: @pinned,
          created_at: @created_at,
          updated_at: (updated_at || @persisted_updated_at || Time.now.iso8601).then { |v| v.is_a?(String) ? v : v.iso8601 },
          working_dir: @working_dir,
          source: @source.to_s,                      # "manual" | "cron" | "channel" | "setup"
          agent_profile: @agent_profile&.name || "", # "general" | "coding" | custom
          todos: @todos,  # Include todos in session data
          time_machine: {  # Include Time Machine state
            task_parents: @task_parents || {},
            current_task_id: @current_task_id || 0,
            active_task_id: @active_task_id || 0,
            task_meta: @task_meta || {}
          },
          config: {
            # NOTE: api_key and other sensitive credentials are intentionally excluded
            # to prevent leaking secrets into session files on disk.
            # model_name is saved so the session can restore its original model on restart
            # (falling back to the current default if the model no longer exists).
            permission_mode: @config.permission_mode.to_s,
            enable_compression: @config.enable_compression,
            enable_idle_compression: @config.enable_idle_compression,
            enable_prompt_caching: @config.enable_prompt_caching,
            max_tokens: @config.max_tokens,
            verbose: @config.verbose,
            reasoning_effort: @reasoning_effort,
            # Persist the current model identity so the session can restore its
            # original model on restart. model_name + model_base_url form a
            # composite key that points at the underlying card (NOT the
            # sub-model overlay) — overlays are layered on top via :sub_model
            # below so card lookup stays stable when the user toggles
            # sub-models.
            model_name: persisted_card_field("model"),
            model_base_url: persisted_card_field("base_url"),
            sub_model: @config.session_model_overlay_name
          },
          channel_info: @channel_info,
          project_id:   @project_id,
          goal:         @goal_manager&.to_h,
          stats: stats_data,
          messages: @history.to_a
        }
      end

      # Get recent user messages from conversation history
      # @param limit [Integer] Number of recent user messages to retrieve (default: 5)
      # @return [Array<String>] Array of recent user message contents
      def get_recent_user_messages(limit: 5)
        @history.real_user_messages.last(limit).map do |msg|
          extract_text_from_content(msg[:content])
        end
      end

      # Replay conversation history by calling ui.show_* methods for each message.
      # Supports cursor-based pagination using created_at timestamps on user messages.
      # Each "round" starts at a user message and includes all subsequent assistant/tool messages.
      # Compressed chunks (chunk_path on assistant messages) are transparently expanded.
      #
      # @param ui [Object] UI interface that responds to show_user_message, show_assistant_message, etc.
      # @param limit [Integer] Maximum number of rounds (user turns) to replay
      # @param before [Float, nil] Unix timestamp cursor — only replay rounds where the user message
      #   created_at < before. Pass nil to get the most recent rounds.
      # @return [Hash] { has_more: Boolean } — whether older rounds exist beyond this page
      def replay_history(ui, limit: 20, before: nil)
        # Split @history into rounds, each starting at a real user message
        rounds = []
        current_round = nil

        @history.to_a.each do |msg|
          role = msg[:role].to_s

          # A real user message can have either a String content or an Array content
          # (Array = multipart: text + image blocks). Exclude system-injected messages
          # and synthetic [SYSTEM] text messages.
          is_real_user_msg = role == "user" && !msg[:system_injected] &&
            if msg[:content].is_a?(String)
              !msg[:content].start_with?("[SYSTEM]")
            elsif msg[:content].is_a?(Array)
              # Must contain at least one text or image block (not a tool_result array).
              # "image_url" covers image-only messages (user sent a picture with no
              # accompanying text); without it such messages start no round and get
              # dropped on replay, making the image vanish on session reopen.
              msg[:content].any? { |b| b.is_a?(Hash) && %w[text image image_url].include?(b[:type].to_s) }
            else
              false
            end

          if is_real_user_msg
            # Start a new round at each real user message.
            # editable: true — this message still lives in the active in-memory
            # @history, so truncate_from_created_at can locate and truncate it.
            current_round = { user_msg: msg, events: [], editable: true }
            rounds << current_round
          elsif current_round
            current_round[:events] << msg
          elsif msg[:compressed_summary]
            # Compressed summary sitting before any user rounds — expand ALL chunk
            # MD files that belong to the same session (siblings of chunk_path),
            # in chunk-index ascending order.
            #
            # Under the current "single summary + previous_chunks index" scheme,
            # session.json only keeps the newest compressed_summary message (which
            # points at the newest chunk). Older chunks (chunk-1..chunk-N-1) are
            # referenced only as basenames inside the summary text. Expanding just
            # msg[:chunk_path] would therefore lose all prior chunks on replay.
            #
            # chunk_path may be blank when a hot restart's SIGKILL killed the
            # worker after the chunk file was written but before its path was
            # persisted into session.json. Fall back to discovering the chunks
            # on disk from session_id + created_at so the history is not lost.
            chunk_paths = if msg[:chunk_path].to_s.empty?
              session_manager.chunks_for_current(@session_id, @created_at).map { |c| c[:path] }
            else
              sibling_chunks_of(msg[:chunk_path])
            end
            chunk_rounds = chunk_paths.flat_map { |p| parse_chunk_md_to_rounds(p) }
            rounds.concat(chunk_rounds)
            # After expanding, treat the last chunk round as the current round so that
            # any orphaned assistant/tool messages that follow in session.json (belonging
            # to the same task whose user message was compressed into the chunk) get
            # appended here instead of being silently discarded.
            current_round = rounds.last unless chunk_rounds.empty?
          elsif rounds.last
            # Orphaned non-user message with no current_round yet (e.g. recent_messages
            # after compression started mid-task with no leading user message).
            # Attach to the last known round rather than drop silently.
            rounds.last[:events] << msg
          end
        end

        # Expand any compressed_summary assistant messages sitting inside a round's events.
        # These occur when compression happened mid-round (rare) — expand them in-place.
        rounds.each do |round|
          round[:events].select! { |ev| !ev[:compressed_summary] }
        end

        # Apply before-cursor filter: only rounds whose user message created_at < before
        if before
          rounds = rounds.select { |r| r[:user_msg][:created_at] && r[:user_msg][:created_at] < before }
        end

        # Fallback: when the conversation was compressed and no user messages remain in the
        # kept slice, render the surviving assistant/tool messages directly so the user can
        # still see the last visible state of the chat (e.g. compressed summary + recent work).
        if rounds.empty?
          visible = @history.to_a.reject { |m| m[:role].to_s == "system" || m[:system_injected] }
          visible.each { |msg| _replay_single_message(msg, ui) }
          return { has_more: false }
        end

        has_more = rounds.size > limit
        # Take the most recent `limit` rounds
        page = rounds.last(limit)

        page.each do |round|
          msg = round[:user_msg]
          raw_text    = msg[:display_text] || extract_text_from_content(msg[:content])
          # Images: recovered from inline image_url blocks in content (carry data_url for <img> rendering)
          image_files = extract_image_files_from_content(msg[:content])
          # Disk files (PDF, doc, etc.): stored in display_files on the user message at send time
          disk_files  = Array(msg[:display_files]).map { |f|
            { name: f[:name] || f["name"], type: f[:type] || f["type"] || "file",
              path: f[:path] || f["path"],
              preview_path: f[:preview_path] || f["preview_path"] }
          }
          all_files = image_files + disk_files
          references = Array(msg[:display_references])
          ref_options = references.empty? ? {} : { references: references }
          task_options = msg[:task_id] ? { task_id: msg[:task_id] } : {}
          ui.show_user_message(raw_text, **task_options, created_at: msg[:created_at], files: all_files,
                               **ref_options,
                               editable: round[:editable] != false,
                               skill_command: msg[:skill_command],
                               skill_command_display: msg[:skill_command_display])
          replay_ext_events(msg, ui)

          round[:events].each do |ev|
            # Skip system-injected messages (e.g. synthetic skill content, memory prompts)
            # — they are internal scaffolding and must not be shown to the user.
            next if ev[:system_injected]

            _replay_single_message(ev, ui)
          end
        end

        { has_more: has_more }
      end

      # Return all chunk MD file paths that belong to the same session as
      # +chunk_path+, sorted by chunk index ascending (chunk-1, chunk-2, …).
      # Uses the filename convention "<base>-chunk-<N>.md".
      #
      # Handles path resolution the same way parse_chunk_md_to_rounds does:
      # if the stored path doesn't exist, fall back to SESSIONS_DIR + basename
      # (cross-machine / cross-user session bundles).
      private def sibling_chunks_of(chunk_path)
        return [] unless chunk_path

        resolved = chunk_path.to_s
        unless File.exist?(resolved)
          resolved = File.join(Clacky::SessionManager::SESSIONS_DIR, File.basename(resolved))
        end
        return [] unless File.exist?(resolved)

        dir  = File.dirname(resolved)
        base = File.basename(resolved).sub(/-chunk-\d+\.md\z/, "")
        return [resolved] if base == File.basename(resolved)  # unconventional name — just use as-is

        Dir.glob(File.join(dir, "#{base}-chunk-*.md")).sort_by do |p|
          m = File.basename(p).match(/-chunk-(\d+)\.md\z/)
          m ? m[1].to_i : Float::INFINITY
        end
      end

      # Parse a chunk MD file into an array of rounds compatible with replay_history.
      # Each round is { user_msg: Hash, events: Array<Hash> }.
      # Timestamps are synthesised from the chunk's archived_at, spread backwards.
      # Recursively expands nested chunk references (compressed summary inside a chunk).
      #
      # @param chunk_path [String] Path to the chunk md file
      # @return [Array<Hash>] rounds array (may be empty if file missing/unreadable)
      private def parse_chunk_md_to_rounds(chunk_path, visited: Set.new)
        return [] unless chunk_path

        # 1. Try the stored absolute path first (same machine, normal case).
        # 2. If not found, fall back to basename + SESSIONS_DIR (cross-user / cross-machine).
        resolved = chunk_path.to_s
        unless File.exist?(resolved)
          resolved = File.join(Clacky::SessionManager::SESSIONS_DIR, File.basename(resolved))
        end

        return [] unless File.exist?(resolved)

        # Guard against circular chunk references (e.g. chunk-3 → chunk-2 → chunk-1 → chunk-9 → … → chunk-3)
        canonical = File.expand_path(resolved)
        if visited.include?(canonical)
          Clacky::Logger.warn("parse_chunk_md_to_rounds: circular reference detected, skipping #{canonical}")
          return []
        end
        visited = visited.dup.add(canonical)

        # Scrub invalid UTF-8 bytes defensively — chunk files written before
        # the 0.9.37 fix may contain poisoned bytes from file_reader results.
        raw = File.read(resolved).then do |s|
          s.encoding == Encoding::UTF_8 && s.valid_encoding? ? s :
            s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\u{FFFD}")
        end

        # Parse YAML front matter to get archived_at for synthetic timestamps
        archived_at = nil
        if raw.start_with?("---")
          fm_end = raw.index("\n---\n", 4)
          if fm_end
            fm_text = raw[4...fm_end]
            fm_text.each_line do |line|
              if line.start_with?("archived_at:")
                archived_at = Time.parse(line.split(":", 2).last.strip) rescue nil
              end
            end
          end
        end
        base_time = (archived_at || Time.now).to_f
        chunk_dir = File.dirname(chunk_path.to_s)

        # Split into sections by ## headings
        sections = []
        current_role       = nil
        current_lines      = []
        current_nested_chunk = nil  # chunk reference from a Compressed Summary heading
        current_task_id    = nil

        raw.each_line do |line|
          stripped = line.chomp
          if (m = stripped.match(/\A## Assistant \[Compressed Summary — original conversation at: (.+)\]/))
            # Nested chunk reference — record it, treat as assistant section
            sections << { role: current_role, lines: current_lines.dup, nested_chunk: current_nested_chunk, task_id: current_task_id } if current_role
            current_role         = "assistant"
            current_lines        = []
            current_nested_chunk = File.join(chunk_dir, m[1])
            current_task_id      = nil
          elsif (m = stripped.match(/\A## (User|Assistant)(?: \[Task ([1-9]\d*)\])?\z/))
            sections << { role: current_role, lines: current_lines.dup, nested_chunk: current_nested_chunk, task_id: current_task_id } if current_role
            current_role         = m[1].downcase
            current_lines        = []
            current_nested_chunk = nil
            current_task_id      = m[2]&.to_i
          elsif stripped.match?(/\A### Tool Result:/)
            sections << { role: current_role, lines: current_lines.dup, nested_chunk: current_nested_chunk, task_id: current_task_id } if current_role
            current_role         = "tool"
            current_lines        = []
            current_nested_chunk = nil
            current_task_id      = nil
          else
            current_lines << line
          end
        end
        sections << { role: current_role, lines: current_lines.dup, nested_chunk: current_nested_chunk, task_id: current_task_id } if current_role

        # Remove front-matter / header noise sections (nil role or non-user/assistant/tool)
        sections.select! { |s| %w[user assistant tool].include?(s[:role]) }

        # Group into rounds: each user section starts a new round
        rounds        = []
        current_round = nil
        round_index   = 0

        sections.each do |sec|
          text = sec[:lines].join.strip
          text, sec_ext_events = extract_ext_events_from_text(text)
          text, sec_display_files = extract_display_files_from_text(text)

          # Nested chunk: expand it recursively, prepend before current rounds
          if sec[:nested_chunk]
            nested = parse_chunk_md_to_rounds(sec[:nested_chunk], visited: visited)
            rounds = nested + rounds unless nested.empty?
            # Also render its summary text as an assistant event in current round if any
            if current_round && !text.empty?
              current_round[:events] << { role: "assistant", content: text }
            end
            next
          end

          next if text.empty? && sec_ext_events.empty? && sec_display_files.empty?

          if sec[:role] == "user"
            round_index += 1
            # Synthetic timestamp: spread rounds backwards from archived_at
            synthetic_ts = base_time - (sections.size - round_index) * 1.0
            user_msg = {
              role: "user",
              content: text,
              created_at: synthetic_ts,
              ext_events: sec_ext_events,
              _from_chunk: true
            }
            user_msg[:task_id] = sec[:task_id] if sec[:task_id]
            user_msg[:display_files] = sec_display_files unless sec_display_files.empty?
            current_round = {
              user_msg: user_msg,
              events: [],
              # editable: false — this message was archived into a chunk MD and no
              # longer exists in the active in-memory @history, so it cannot be
              # truncated/edited (truncate_from_created_at would silently no-op).
              editable: false
            }
            rounds << current_round
          elsif current_round
            if sec[:role] == "assistant"
              # Detect "_Tool calls: ..._" lines — convert to tool_calls events
              # so _replay_single_message renders them as tool group UI (same as live).
              #
              # Formats supported:
              #   New: "_Tool calls: name | {"arg":"val"}; name2 | {"k":"v"}_"
              #   Old: "_Tool calls: name1, name2_"  (backward compat)
              remaining_lines = []
              pending_tool_entries = []  # [{name:, args:}]

              text.each_line do |line|
                stripped = line.strip
                if (m = stripped.match(/\A_Tool calls?:\s*(.+?)_?\z/i))
                  raw = m[1]
                  pending_tool_entries.concat(parse_tool_calls_line(raw))
                else
                  remaining_lines << line
                end
              end

              # Flush any plain text
              plain_text = remaining_lines.join.strip
              current_round[:events] << { role: "assistant", content: plain_text } unless plain_text.empty?

              # Emit one synthetic tool_calls message per detected tool
              pending_tool_entries.each do |entry|
                current_round[:events] << {
                  role: "assistant",
                  content: "",
                  tool_calls: [{ name: entry[:name], arguments: entry[:args] }]
                }
              end

              attach_ext_events_to_last(current_round, sec_ext_events)
            else
              current_round[:events] << { role: "tool", content: text }
              attach_ext_events_to_last(current_round, sec_ext_events)
            end
          end
        end

        rounds
      rescue => e
        Clacky::Logger.warn("parse_chunk_md_to_rounds failed for #{chunk_path}: #{e.message}")
        []
      end


      # Pull lightweight attachment badge metadata out of a chunk section.
      # The marker is internal archive data and must not appear in replayed text.
      # Only name + type are accepted; paths and file contents are never restored.
      def extract_display_files_from_text(text)
        return [text, []] unless text.include?("_Display files:")

        files = []
        kept = text.each_line.reject do |line|
          match = line.strip.match(/\A_Display files:\s*(\[.*\])_?\z/i)
          next false unless match

          parsed = JSON.parse(match[1]) rescue []
          Array(parsed).each do |file|
            next unless file.is_a?(Hash)

            name = file["name"] || file[:name]
            next if name.nil? || name.to_s.strip.empty?

            type = file["type"] || file[:type] || "file"
            type = "file" if type.to_s.strip.empty?
            files << { name: name.to_s, type: type.to_s }
          end
          true
        end

        [kept.join.strip, files]
      end


      # Pull the "_Ext events: type | {json}; ..._" line out of a chunk section,
      # returning the remaining text plus the parsed events. Counterpart to
      # MessageCompressorHelper#append_ext_events_line.
      def extract_ext_events_from_text(text)
        return [text, []] unless text.include?("_Ext events:")

        events = []
        kept = text.each_line.reject do |line|
          m = line.strip.match(/\A_Ext events?:\s*(.+?)_?\z/i)
          next false unless m

          parse_piped_entries(m[1]).each do |entry|
            next if entry[:args].nil?

            events << { type: entry[:name], data: entry[:args] }
          end
          true
        end

        [kept.join.strip, events]
      end

      # Split a "_Tool calls:_" payload into entries. The separator ";" also
      # occurs inside args JSON (shell commands, JS snippets), so entry
      # boundaries are found by brace balancing rather than String#split.
      def parse_tool_calls_line(raw)
        parse_piped_entries(raw).map { |e| { name: e[:name], args: e[:args] || {} } }
      end

      # Scan a "name | {json}; name | {json}" payload. Shared by the
      # "_Tool calls:" and "_Ext events:" chunk MD lines, whose ";" separator
      # is ambiguous with semicolons inside the JSON values. Entries with no
      # JSON payload yield args: nil so callers can tell "absent" from "empty".
      def parse_piped_entries(raw)
        return [] if raw.nil?

        scanner = StringScanner.new(raw)
        entries = []

        until scanner.eos?
          scanner.skip(/[;,]?\s*/)
          break if scanner.eos?

          name = scanner.scan(/[^|;,]+?(?=\s*\|\s*\{)/)
          unless name
            plain = scanner.scan(/[^;,]+/)
            break unless plain

            plain = plain.strip
            entries << { name: plain, args: nil } unless plain.empty?
            next
          end

          scanner.skip(/\s*\|\s*/)
          json = scan_balanced_json(scanner)
          next unless json

          parsed = JSON.parse(json) rescue nil
          entries << { name: name.strip, args: parsed.is_a?(Hash) ? parsed : {} }
        end

        entries
      end

      # Consume one balanced {...} literal, ignoring braces inside JSON strings.
      def scan_balanced_json(scanner)
        start = scanner.pos
        return nil unless scanner.getch == "{"

        depth = 1
        in_string = false
        escaped = false

        while (ch = scanner.getch)
          if escaped
            escaped = false
          elsif ch == "\\"
            escaped = true
          elsif ch == '"'
            in_string = !in_string
          elsif !in_string && ch == "{"
            depth += 1
          elsif !in_string && ch == "}"
            depth -= 1
            return scanner.string[start...scanner.pos] if depth.zero?
          end
        end

        nil
      end

      # Anchor chunk-restored events to the last message of the round so they
      # replay after it, matching where they were emitted live.
      def attach_ext_events_to_last(round, events)
        return if events.nil? || events.empty?

        target = round[:events].last || round[:user_msg]
        return unless target

        target[:ext_events] = Array(target[:ext_events]) + events
      end

      # Render a single non-user message into the UI.
      # Used by both the normal round-based replay and the compressed-session fallback.
      def _replay_single_message(msg, ui)
        return if msg[:system_injected]

        case msg[:role].to_s
        when "assistant"
          # Mirror the live guard at agent.rb (`if response[:content] && !response[:content].empty?`):
          # only emit an assistant_message when the model produced actual content.
          # Reasoning-only turns (empty content + reasoning_content + tool_calls)
          # are silent in live mode; on replay they must stay silent too — otherwise
          # a phantom <think>-only bubble splits consecutive tool_calls into separate
          # UI groups, breaking the "N tool(s) used" collapse after refresh (C-5672).
          raw_text  = extract_text_from_content(msg[:content]).to_s.strip
          reasoning = msg[:reasoning_content]
          unless raw_text.empty?
            text = if reasoning && !reasoning.to_s.strip.empty?
              # Prepend reasoning wrapped in <think> tags so the Web UI renders it
              # as a collapsible thinking block.
              "<think>\n#{reasoning}\n</think>\n#{raw_text}"
            else
              raw_text
            end
            ui.show_assistant_message(text, files: [], created_at: msg[:created_at])
          end

          # Tool calls embedded in assistant message
          Array(msg[:tool_calls]).each do |tc|
            name     = tc[:name] || tc.dig(:function, :name) || ""
            args_raw = tc[:arguments] || tc.dig(:function, :arguments) || {}
            args     = args_raw.is_a?(String) ? (JSON.parse(args_raw) rescue args_raw) : args_raw

            # Special handling: the ask_user question is shown as an assistant
            # message (matching real-time behavior), not as a tool call.
            if Clacky::Tools::AskUser.feedback_tool?(name)
              questions = Clacky::Tools::AskUser.normalize_questions(args)
              context   = Clacky::Tools::AskUser.fetch_key(args, :context).to_s
              first     = questions.first

              unless first.nil?
                ui.show_feedback_request(first[:question], context, first[:options],
                                         questions: questions)
              end
            else
              ui.show_tool_call(name, args)
            end
          end

          # Emit token usage stored on this message (for history replay display)
          ui.show_token_usage(msg[:token_usage]) if msg[:token_usage]

          # Interrupted fan-out anchors its captured subagent trails onto the
          # last message, which is usually this assistant turn (its tool result
          # never got written). Replay them here so they survive a reload.
          replay_subagent_transcript(msg, ui)

        when "user"
          # Anthropic-format tool results (role: user, content: array of tool_result blocks)
          if msg[:content].is_a?(Array)
            msg[:content].each do |blk|
              next unless blk.is_a?(Hash) && blk[:type] == "tool_result"

              ui.show_tool_result(blk[:content].to_s)
            end
            replay_subagent_transcript(msg, ui)
          end

        when "tool"
          # OpenAI-format tool result
          ui.show_tool_result(msg[:content].to_s)
          replay_subagent_transcript(msg, ui)
        end

        replay_ext_events(msg, ui)
      end

      # Re-emit custom extension events recorded on a message so extension
      # panels can rebuild their state after a page reload. Mirrors what
      # Agent#emit_event pushed live. No-op when the message carries none.
      def replay_ext_events(msg, ui)
        Array(msg[:ext_events]).each do |ev|
          next unless ev.is_a?(Hash)

          type = ev[:type] || ev["type"]
          next if type.nil? || type.to_s.empty?

          data = ev[:data] || ev["data"] || {}
          data = data.is_a?(Hash) ? data.transform_keys(&:to_sym) : {}
          ui.emit(type.to_s, **data)
        end
      end

      # Replay subagent transcripts stored on a tool result message. Emits a
      # bracketed sequence of UI events the frontend can render as a collapsible
      # sub-process block: subagent_start → (assistant_message / tool_call /
      # tool_result)* → subagent_end. A fan-out batch renders one block per job,
      # in the caller's original job order.
      #
      # Sessions saved before fan-out support stored a bare Hash here.
      def replay_subagent_transcript(msg, ui)
        stored = msg[:subagent_transcript]
        Array(stored.is_a?(Hash) ? [stored] : stored).each do |transcript|
          next unless transcript.is_a?(Hash)

          replay_one_subagent_transcript(transcript, ui)
        end
      end

      def replay_one_subagent_transcript(transcript, ui)
        events = transcript[:events] || transcript["events"] || []
        return if events.empty?

        skill = transcript[:skill] || transcript["skill"]
        supports_phase = ui.respond_to?(:phase_start) && ui.respond_to?(:phase_end)
        pid = ui.phase_start(kind: "fanout_subagent", label: skill) if supports_phase

        ui.show_subagent_start(
          skill:      skill,
          iterations: transcript[:iterations] || transcript["iterations"],
          cost_usd:   transcript[:cost_usd]   || transcript["cost_usd"]
        )

        events.each do |ev|
          role = (ev[:role] || ev["role"]).to_s
          content = ev[:content] || ev["content"]
          tool_calls = ev[:tool_calls] || ev["tool_calls"]

          case role
          when "assistant"
            text = extract_text_from_content(content).to_s.strip
            ui.show_assistant_message(text, files: [], created_at: ev[:created_at] || ev["created_at"]) unless text.empty?
            Array(tool_calls).each do |tc|
              name = tc[:name] || tc["name"] || ""
              args_raw = tc[:arguments] || tc["arguments"] || {}
              args = args_raw.is_a?(String) ? (JSON.parse(args_raw) rescue args_raw) : args_raw
              ui.show_tool_call(name, args)
            end
          when "tool", "user"
            ui.show_tool_result(extract_text_from_content(content).to_s)
          end
        end

        ui.show_subagent_end
        ui.phase_end(pid) if supports_phase && pid
      end

      # Replace the system message in @messages with a freshly built system prompt.
      # Called after restore_session so newly installed skills and any other
      # configuration changes since the session was saved take effect immediately.
      # If no system message exists yet (shouldn't happen in practice), a new one
      # is prepended so the conversation stays well-formed.
      def refresh_system_prompt
        # Reload skills from disk to pick up anything installed since the session was saved
        @skill_loader.load_all

        fresh_prompt = build_system_prompt
        @history.replace_system_prompt(fresh_prompt)
      rescue StandardError => e
        # Log and continue — a stale system prompt is better than a broken restore
        Clacky::Logger.warn("refresh_system_prompt failed during session restore: #{e.message}")
      end

      # Extract base64 data URLs from multipart content (image blocks).
      # Returns an empty array when there are no images or content is plain text.
      # @param content [String, Array, Object] Message content
      # @return [Array<String>] Array of data URLs (e.g. "data:image/png;base64,...")
      def extract_images_from_content(content)
        return [] unless content.is_a?(Array)

        content.filter_map do |block|
          next unless block.is_a?(Hash)

          case block[:type].to_s
          when "image_url"
            # OpenAI format: { type: "image_url", image_url: { url: "data:image/png;base64,..." } }
            block.dig(:image_url, :url)
          when "image"
            # Anthropic format: { type: "image", source: { type: "base64", media_type: "image/png", data: "..." } }
            source = block[:source]
            next unless source.is_a?(Hash) && source[:type].to_s == "base64"

            "data:#{source[:media_type]};base64,#{source[:data]}"
          when "document"
            # Anthropic PDF document block — return a sentinel string for frontend display
            source = block[:source]
            next unless source.is_a?(Hash) && source[:media_type].to_s == "application/pdf"

            # Return a special marker so the frontend can render a PDF badge instead of an <img>
            "pdf:#{source[:data]&.then { |d| d[0, 32] }}"  # prefix to identify without full payload
          end
        end
      end

      # Extract text from message content (handles string and array formats)
      # @param content [String, Array, Object] Message content
      # @return [String] Extracted text
      def extract_text_from_content(content)
        if content.is_a?(String)
          content
        elsif content.is_a?(Array)
          # Extract text from content array (may contain text and images)
          text_parts = content.select { |c| c.is_a?(Hash) && c[:type] == "text" }
          text_parts.map { |c| c[:text] }.join("\n")
        else
          content.to_s
        end
      end

      # Extract images from a multipart content array and return them as file entries.
      # Returns an array of { name:, mime_type:, data_url: } hashes — the same structure
      # that the frontend sends via `files` in a message, and that show_user_message(files:) expects.
      # Only includes inline data_url images (not remote URLs).
      def extract_image_files_from_content(content)
        return [] unless content.is_a?(Array)

        content.each_with_index.filter_map do |block, idx|
          next unless block.is_a?(Hash)
          # OpenAI-style: { type: "image_url", image_url: { url: "data:image/png;base64,..." } }
          next unless block[:type] == "image_url"

          url = block.dig(:image_url, :url)
          # image_path is stored at send-time so replay can reconstruct the image from tmp
          path = block[:image_path]

          next unless url&.start_with?("data:") || path

          mime_type = (url || "")[/\Adata:([^;]+);/, 1] || "image/jpeg"
          ext       = mime_type.split("/").last
          { name: "image_#{idx + 1}.#{ext}", mime_type: mime_type, data_url: url, path: path }
        end
      end

      # Inject a chunk index card into the conversation when archived chunks exist.
      # Lists all chunk files (path + topics + turn count) so the AI knows where to
      # look if it needs details from past conversations. The AI can load any chunk
      # on demand using the existing file_reader tool — no new tools required.
      #
      # Only re-injects when a new chunk has been added since the last injection,
      # keeping the message list clean across multiple compressions.
      #
      # Cache-safe: injected as a system_injected user message in the conversation
      # turns, never touching the system prompt.
      def inject_chunk_index_if_needed
        # Collect all compressed_summary messages that carry a chunk_path
        chunk_msgs = @history.to_a.select { |m| m[:compressed_summary] && m[:chunk_path] }
        return if chunk_msgs.empty?

        # Skip if we already injected an index for this exact chunk count
        return if @history.last_injected_chunk_count == chunk_msgs.size

        # Remove any previously injected chunk index (stale — chunk count changed)
        @history.delete_where { |m| m[:chunk_index] }

        # Build index card lines
        lines = ["## Previous Session Archives (#{chunk_msgs.size} chunk#{"s" if chunk_msgs.size > 1} available)\n"]
        chunk_msgs.each_with_index do |msg, i|
          path   = msg[:chunk_path].to_s
          topics = read_chunk_topics(path)
          turns  = read_chunk_message_count(path)
          lines << "[CHUNK-#{i + 1}] #{path}"
          lines << "  Topics: #{topics}" if topics
          lines << "  Turns: #{turns}"   if turns
          lines << ""
        end
        lines << "Use file_reader to load a chunk file when you need original conversation details."

        @history.append({
          role: "user",
          content: lines.join("\n"),
          system_injected: true,
          chunk_index: true,
          chunk_count: chunk_msgs.size
        })
      end

      # Read the `topics` field from a chunk MD file's YAML front matter.
      # Returns nil if the file is missing or has no topics field.
      private def read_chunk_topics(chunk_path)
        return nil unless chunk_path && File.exist?(chunk_path)
        File.foreach(chunk_path) do |line|
          return line.sub(/^topics:\s*/, "").strip if line.start_with?("topics:")
          break if line.strip == "---" && $. > 1  # end of front matter
        end
        nil
      rescue
        nil
      end

      # Read the `message_count` field from a chunk MD file's YAML front matter.
      # Returns nil if the file is missing or has no message_count field.
      private def read_chunk_message_count(chunk_path)
        return nil unless chunk_path && File.exist?(chunk_path)
        File.foreach(chunk_path) do |line|
          return line.sub(/^message_count:\s*/, "").strip.to_i if line.start_with?("message_count:")
          break if line.strip == "---" && $. > 1
        end
        nil
      rescue
        nil
      end
    end
  end
end
