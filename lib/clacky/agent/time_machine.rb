# frozen_string_literal: true

require "fileutils"
require "set"

module Clacky
  class Agent
    # Time Machine module for task history management with undo/redo support.
    #
    # Snapshots capture the BEFORE state of each file the moment a task first
    # touches it (via record_file_before_change). task-N/ therefore holds
    # "what every file looked like just before task N changed it" — including
    # an .absent marker for files that did not yet exist. Restoring to task T
    # replays the earliest BEFORE recorded in any task after T, which equals
    # the on-disk state at the end of task T.
    module TimeMachine
      # Marker file written alongside a snapshot path when the original file
      # did not exist before the task changed it. Restoring such an entry
      # deletes the file instead of copying content back.
      ABSENT_MARKER = ".clacky-absent"

      # Root directory holding per-session file snapshots.
      def self.snapshots_root
        File.join(Dir.home, ".clacky", "snapshots")
      end

      # Snapshot directory for a single session.
      def self.session_dir(session_id)
        File.join(snapshots_root, session_id.to_s)
      end

      # Remove all snapshots for a session. Safe to call when none exist.
      def self.delete_session_snapshots(session_id)
        return if session_id.to_s.empty?

        FileUtils.rm_rf(session_dir(session_id))
      end

      # Initialize Time Machine state
      private def init_time_machine
        @task_parents ||= {}      # { task_id => parent_id }
        @current_task_id ||= 0    # Latest created task ID
        @active_task_id ||= 0     # Current active task ID (for undo/redo)
        @task_meta ||= {}         # { task_id => { title:, started_at:, ended_at: } }
        @latest_after_dirty = false if @latest_after_dirty.nil?
      end

      # Start a new task and establish parent relationship
      # @param title [String, nil] Short label for this turn (typically the
      #   user's first message, truncated). Used by the UI to label snapshots
      #   even after the original conversation has been compressed out of
      #   @history. nil → leave unset; the UI falls back to "Task N".
      # Made public for testing
      def start_new_task(title: nil)
        # Before the currently-active task stops being the latest, freeze its
        # end-of-task disk state into an AFTER snapshot. Without this, a task
        # that later gets superseded by a sibling branch would have no record
        # of its result, making a forward switch back to it impossible.
        checkpoint_latest_task_after

        # Close out the task we're leaving.
        if @active_task_id.to_i > 0 && @task_meta[@active_task_id]
          @task_meta[@active_task_id][:ended_at] ||= Time.now.to_f
        end

        parent_id = @active_task_id
        @current_task_id += 1
        @active_task_id = @current_task_id
        @task_parents[@current_task_id] = parent_id

        @task_meta[@current_task_id] = {
          title: title ? truncate_task_title(title) : nil,
          started_at: Time.now.to_f,
          ended_at: nil,
        }

        # Claim ownership of this task for the current thread.
        # If a stale thread (e.g. a slow subagent) wakes up later it will see
        # @task_thread != Thread.current via check_stale! and self-terminate
        # before it can write to history.
        @task_thread = Thread.current

        @latest_after_dirty = true

        @current_task_id
      end

      # Update the title of the currently-active task. Used by callers that
      # only learn the user-facing label after start_new_task has run.
      def set_current_task_title(title)
        return if @active_task_id.to_i <= 0
        @task_meta[@active_task_id] ||= { started_at: Time.now.to_f, ended_at: nil }
        @task_meta[@active_task_id][:title] = truncate_task_title(title)
      end

      private def truncate_task_title(text)
        s = text.to_s
        # Collapse whitespace so multi-line inputs render as a single label.
        s = s.gsub(/\s+/, " ").strip
        s.length > 60 ? "#{s[0...57]}..." : s
      end

      # Record a file's BEFORE state for the current task, the first time the
      # task touches it. Call this immediately before a tool mutates the file.
      # Subsequent calls within the same task are no-ops so the earliest state
      # (the true "before this task" snapshot) is preserved.
      # Made public for testing
      def record_file_before_change(file_path)
        return if @current_task_id.to_i <= 0

        full_path = File.expand_path(file_path.to_s, @working_dir)
        rel = snapshot_relative_path(full_path)
        before_dir = File.join(TimeMachine.session_dir(@session_id), "task-#{@current_task_id}", "before")
        snapshot_file = File.join(before_dir, rel)
        marker_file   = "#{snapshot_file}.#{ABSENT_MARKER}"

        # Already recorded for this task — keep the earliest capture.
        return if File.exist?(snapshot_file) || File.exist?(marker_file)

        # A fresh change to the latest task invalidates its stale AFTER checkpoint.
        @latest_after_dirty = true

        FileUtils.mkdir_p(File.dirname(snapshot_file))
        if File.exist?(full_path)
          FileUtils.cp(full_path, snapshot_file)
        else
          # File did not exist before this task — mark it so a restore deletes it.
          FileUtils.touch(marker_file)
        end
      rescue StandardError
        # Snapshotting must never break the actual file operation.
      end

      # Snapshot a task's current on-disk state into its AFTER tree, so a
      # forward switch (redo / branch switch) back to it can be reconstructed.
      # Only the files the task touched (its BEFORE entries) are captured.
      # Defaults to the active task, which holds the live disk state right
      # before we leave it (start_new_task / switch).
      private def checkpoint_latest_task_after(task_id = @active_task_id)
        return if task_id.to_i <= 0
        # Re-snapshotting the latest task is skipped when nothing changed.
        return if task_id == @current_task_id && @latest_after_dirty == false

        session_root = TimeMachine.session_dir(@session_id)
        before_dir = File.join(session_root, "task-#{task_id}", "before")
        return unless Dir.exist?(before_dir)

        after_dir = File.join(session_root, "task-#{task_id}", "after")
        FileUtils.rm_rf(after_dir)

        Dir.glob(File.join(before_dir, "**", "*"), File::FNM_DOTMATCH).each do |path|
          next if File.directory?(path)

          rel = path.sub(before_dir + "/", "")
          rel = rel.sub(/\.#{Regexp.escape(ABSENT_MARKER)}\z/, "")
          target = File.join(@working_dir, rel)
          dest = File.join(after_dir, rel)
          if File.exist?(target)
            FileUtils.mkdir_p(File.dirname(dest))
            FileUtils.cp(target, dest)
          else
            FileUtils.mkdir_p(File.dirname(dest))
            FileUtils.touch("#{dest}.#{ABSENT_MARKER}")
          end
        end
        @latest_after_dirty = false if task_id == @current_task_id
      rescue StandardError
        # Checkpointing must never break a restore.
      end

      # Restore files to the on-disk state at the END of the given task.
      #
      # History is a TREE (undo + a new message forks a sibling branch), so a
      # linear "replay every task after T" model is wrong: a sibling branch's
      # files would leak in or get wrongly deleted. Instead we reconstruct T's
      # end state from the task tree:
      #
      #   * Each task owns an AFTER snapshot = the content of the files it
      #     touched, as they looked when that task finished.
      #   * To rebuild "end of task T", walk T's ancestor chain (T -> root).
      #     For every file ever touched in the whole session, the winning
      #     content is the closest ancestor (starting at T) whose AFTER holds
      #     that file. If no ancestor on the chain ever touched it, the file
      #     did not exist at T and is removed.
      #
      # @param task_id [Integer] Target task ID
      # Made public for testing
      def restore_to_task_state(task_id)
        # Freeze the task we're leaving so a later forward switch can return.
        checkpoint_latest_task_after

        plan = build_restore_plan(task_id)
        plan.each do |rel, decision|
          target = File.join(@working_dir, rel)
          if decision[:action] == :delete
            FileUtils.rm_f(target)
          else
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.cp(decision[:source], target)
          end
        end
      rescue StandardError
        raise
      end

      # Decide, for every file the session has ever touched, whether restoring
      # to `task_id` should overwrite it with a snapshot or delete it. Pure
      # function over the snapshot tree — does not touch the working dir.
      # @return [Hash{String => Hash}] rel_path => { action: :delete | :restore, source: String|nil }
      private def build_restore_plan(task_id)
        session_root = TimeMachine.session_dir(@session_id)

        ancestors = []
        tid = task_id
        until tid.nil? || tid <= 0 || ancestors.include?(tid)
          ancestors << tid
          tid = @task_parents[tid]
        end

        all_rels = Set.new
        Dir.glob(File.join(session_root, "task-*", "before", "**", "*"), File::FNM_DOTMATCH).each do |path|
          next if File.directory?(path)
          rel = path.sub(%r{\A.*/before/}, "")
          rel = rel.sub(/\.#{Regexp.escape(ABSENT_MARKER)}\z/, "")
          all_rels << rel
        end

        plan = {}
        all_rels.each do |rel|
          action = :delete
          source = nil
          matched = false

          ancestors.each do |aid|
            after_dir = File.join(session_root, "task-#{aid}", "after")
            content_path = File.join(after_dir, rel)
            absent_path  = "#{content_path}.#{ABSENT_MARKER}"

            if File.exist?(content_path)
              action = :restore
              source = content_path
              matched = true
              break
            elsif File.exist?(absent_path)
              action = :delete
              matched = true
              break
            end
          end

          unless matched
            initial = earliest_before_snapshot(session_root, rel)
            if initial
              action = :restore
              source = initial
            else
              action = :delete
            end
          end

          plan[rel] = { action: action, source: source }
        end

        plan
      end

      # Preview the file-level effect of restore_to_task_state(task_id) without
      # touching disk. Compares the resolved restore plan against the current
      # working-dir state and returns only files that would actually change.
      # @return [Array<Hash>] [{ path:, action: "create"|"modify"|"delete" }]
      def preview_restore_to_task(task_id)
        return [] unless task_id.is_a?(Integer) && task_id >= 0

        checkpoint_latest_task_after
        plan = build_restore_plan(task_id)
        changes = []

        plan.each do |rel, decision|
          target = File.join(@working_dir, rel)
          target_exists = File.exist?(target)

          if decision[:action] == :delete
            changes << { path: rel, action: "delete" } if target_exists
          else
            src = decision[:source]
            next unless src && File.exist?(src)

            if !target_exists
              changes << { path: rel, action: "create" }
            elsif !files_equal?(src, target)
              changes << { path: rel, action: "modify" }
            end
          end
        end

        changes.sort_by { |c| c[:path] }
      end

      private def files_equal?(a, b)
        return false unless File.size(a) == File.size(b)
        File.binread(a) == File.binread(b)
      rescue StandardError
        false
      end

      # The initial (pre-session) content path for a file, taken from the
      # earliest BEFORE snapshot any task recorded for it. Returns the snapshot
      # path to copy back, or nil if the earliest record is an absent marker
      # (file did not exist at the session start).
      private def earliest_before_snapshot(session_root, rel)
        task_ids = Dir.glob(File.join(session_root, "task-*")).filter_map do |dir|
          m = File.basename(dir).match(/\Atask-(\d+)\z/)
          m && m[1].to_i
        end.sort

        task_ids.each do |tid|
          before_dir = File.join(session_root, "task-#{tid}", "before")
          content_path = File.join(before_dir, rel)
          absent_path  = "#{content_path}.#{ABSENT_MARKER}"
          return content_path if File.exist?(content_path)
          return nil if File.exist?(absent_path)
        end
        nil
      end

      # Relative path used to key a snapshot. Files inside the working dir keep
      # their relative path; anything else falls back to its basename.
      private def snapshot_relative_path(full_path)
        if full_path.start_with?(@working_dir + "/")
          full_path.sub(@working_dir + "/", "")
        else
          File.basename(full_path)
        end
      end

      # Filter messages to only the active task's ancestor chain.
      # After an undo (and especially after sending a NEW message post-undo,
      # which forks a fresh task off the undone point) the history still holds
      # the abandoned/sibling-branch turns. We must send the LLM only the turns
      # on the path from the root to the active task — never undone siblings.
      # Returns API-ready array (strips internal fields + repairs orphaned
      # tool_calls), so this stays consistent with the normal to_api path.
      # @param force_reasoning_content_pad [Boolean] forwarded to MessageHistory,
      #   enables one-shot pad-and-retry for thinking-mode providers that
      #   require reasoning_content on every assistant message.
      # Made public for testing
      def active_messages(force_reasoning_content_pad: false)
        @history.to_api(
          force_reasoning_content_pad: force_reasoning_content_pad,
          task_chain: active_task_chain
        )
      end

      # The set of task IDs on the path from the root to @active_task_id,
      # walked via @task_parents. Used to filter history so undone or
      # sibling-branch turns are excluded from what the LLM sees. Task 0 is the
      # root and is always included when reached (early turns are tagged 0).
      private def active_task_chain
        chain = Set.new
        tid = @active_task_id
        # Guard against a malformed parent map producing a cycle.
        until tid.nil? || chain.include?(tid)
          chain << tid
          break if tid <= 0
          tid = @task_parents[tid]
        end
        chain
      end

      # Undo to parent task. Task 0 represents the original pre-task state,
      # which is reachable from task 1 thanks to its BEFORE snapshots.
      def undo_last_task
        return { success: false, message: "Already at root task" } if @active_task_id == 0

        parent_id = @task_parents[@active_task_id]
        return { success: false, message: "Already at root task" } if parent_id.nil?

        restore_to_task_state(parent_id)
        @active_task_id = parent_id

        {
          success: true,
          message: "⏪ Undone to task #{parent_id}",
          task_id: parent_id
        }
      end

      # Switch to specific task (for redo or branch switching)
      def switch_to_task(target_task_id)
        if target_task_id > @current_task_id || target_task_id < 1
          return { success: false, message: "Invalid task ID: #{target_task_id}" }
        end

        restore_to_task_state(target_task_id)
        @active_task_id = target_task_id

        {
          success: true,
          message: "⏩ Switched to task #{target_task_id}",
          task_id: target_task_id
        }
      end

      # Get children of a task (for branch detection)
      def get_child_tasks(task_id)
        @task_parents.select { |_, parent| parent == task_id }.keys
      end

      # Cheap version of task_diff_files: just count how many distinct files
      # this task touched, so the timeline can grey out no-op tasks without
      # paying for a full diff walk per row.
      def task_change_count(task_id)
        return 0 unless task_id.is_a?(Integer) && task_id > 0

        session_root = TimeMachine.session_dir(@session_id)
        before_dir = File.join(session_root, "task-#{task_id}", "before")
        after_dir  = File.join(session_root, "task-#{task_id}", "after")
        return 0 unless Dir.exist?(before_dir)
        return 0 if task_id == @current_task_id && @latest_after_dirty == true && !Dir.exist?(after_dir)

        rels = Set.new
        [before_dir, after_dir].each do |root|
          next unless Dir.exist?(root)
          Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each do |path|
            next if File.directory?(path)
            rel = path.sub(root + "/", "").sub(/\.#{Regexp.escape(ABSENT_MARKER)}\z/, "")
            rels << rel
          end
        end
        rels.size
      end

      # File-level summary of changes a task introduced. Diff is task-N/before
      # vs task-N/after (after is captured by checkpoint_latest_task_after when
      # the task stops being the latest, so this method has no useful answer
      # for the currently-active task — callers get an empty list back).
      # @return [Array<Hash>] Each entry: { path:, status: "added"|"modified"|"deleted", binary: Bool }
      def task_diff_files(task_id)
        return [] unless task_id.is_a?(Integer) && task_id > 0

        session_root = TimeMachine.session_dir(@session_id)
        before_dir = File.join(session_root, "task-#{task_id}", "before")
        after_dir  = File.join(session_root, "task-#{task_id}", "after")
        return [] unless Dir.exist?(before_dir)
        return [] if task_id == @current_task_id && @latest_after_dirty == true && !Dir.exist?(after_dir)

        rels = Set.new
        [before_dir, after_dir].each do |root|
          next unless Dir.exist?(root)
          Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each do |path|
            next if File.directory?(path)
            rel = path.sub(root + "/", "").sub(/\.#{Regexp.escape(ABSENT_MARKER)}\z/, "")
            rels << rel
          end
        end

        rels.sort.map do |rel|
          before_file, before_absent = snapshot_paths(before_dir, rel)
          after_file,  after_absent  = snapshot_paths(after_dir,  rel)

          status = if before_absent && after_file
            "added"
          elsif before_file && after_absent
            "deleted"
          elsif before_file && after_file
            "modified"
          elsif before_file && !File.exist?(after_dir)
            # No AFTER captured (e.g. the very latest task) — still surface
            # what was touched as "modified" so the UI can list the file.
            "modified"
          else
            "modified"
          end

          binary = looks_binary?(before_file) || looks_binary?(after_file)
          { path: rel, status: status, binary: binary }
        end
      end

      # Unified diff of a single file for a task. Returns nil if either side
      # is missing or binary. text format = "@@ ... @@" patch (3-context),
      # ready for the UI to render with a diff renderer.
      # @return [Hash, nil] { path:, before:, after:, patch:, binary: }
      def task_file_diff(task_id, rel_path)
        return nil unless task_id.is_a?(Integer) && task_id > 0
        return nil if rel_path.to_s.include?("..")

        session_root = TimeMachine.session_dir(@session_id)
        before_dir = File.join(session_root, "task-#{task_id}", "before")
        after_dir  = File.join(session_root, "task-#{task_id}", "after")

        before_file, before_absent = snapshot_paths(before_dir, rel_path)
        after_file,  after_absent  = snapshot_paths(after_dir,  rel_path)

        before_text = before_absent ? "" : (before_file ? read_text_safe(before_file) : nil)
        after_text  = after_absent  ? "" : (after_file  ? read_text_safe(after_file)  : nil)

        if before_text.nil? && after_text.nil?
          return nil
        end

        # Detect binary on either side: bail out, the UI will render a stub.
        if (before_file && looks_binary?(before_file)) || (after_file && looks_binary?(after_file))
          return { path: rel_path, before: nil, after: nil, patch: nil, binary: true }
        end

        require "diffy" unless defined?(Diffy)
        raw = Diffy::Diff.new(before_text || "", after_text || "",
                              context: 3, include_diff_info: true).to_s(:text)
        # Strip Diffy's "--- /tmp/diffy.../before" header pair: it leaks
        # tempfile paths and adds noise the UI doesn't need.
        patch = raw.sub(/\A(?:---[^\n]*\n[^\n]*\n)/, "")

        { path: rel_path, before: before_text, after: after_text, patch: patch, binary: false }
      end

      private def snapshot_paths(dir, rel)
        content_path = File.join(dir, rel)
        absent_path  = "#{content_path}.#{ABSENT_MARKER}"
        if File.exist?(content_path)
          [content_path, false]
        elsif File.exist?(absent_path)
          [nil, true]
        else
          [nil, false]
        end
      end

      private def looks_binary?(path)
        return false if path.nil? || !File.exist?(path)
        sample = File.binread(path, 8000)
        sample.include?("\x00") || !sample.dup.force_encoding("UTF-8").valid_encoding?
      rescue StandardError
        true
      end

      private def read_text_safe(path)
        File.read(path, mode: "rb").then do |s|
          s.encoding == Encoding::UTF_8 && s.valid_encoding? ? s :
            s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\u{FFFD}")
        end
      rescue StandardError
        ""
      end

      # Get task history with summaries for UI display
      # @param limit [Integer] Maximum number of recent tasks to return
      # @return [Array<Hash>] Task history with metadata
      def get_task_history(limit: 10)
        return [] if @current_task_id == 0

        chain = active_task_chain

        tasks = []
        (1..@current_task_id).to_a.reverse.take(limit).reverse.each do |task_id|
          meta = (@task_meta || {})[task_id] || {}

          summary = if meta[:title] && !meta[:title].to_s.empty?
            meta[:title]
          else
            # Best-effort fallback: scan @history for the task's first real
            # user message. Returns nothing for tasks that have already been
            # compressed out — the UI then shows "Task N".
            first = @history.to_a.find do |msg|
              msg[:role] == "user" && msg[:task_id] == task_id && !msg[:system_injected]
            end
            if first
              text = extract_message_text(first[:content]).to_s.gsub(/\s+/, " ").strip
              text.length > 60 ? "#{text[0...57]}..." : text
            else
              "Task #{task_id}"
            end
          end

          # Status relative to the ACTIVE task chain (not a linear id compare),
          # so undone/abandoned branches are flagged distinctly from the path
          # the user is currently on.
          status = if task_id == @active_task_id
            :current
          elsif chain.include?(task_id)
            :past
          else
            :undone
          end

          # Check if task has branches (multiple children)
          children = get_child_tasks(task_id)
          has_branches = children.length > 1

          tasks << {
            task_id: task_id,
            parent_task_id: @task_parents[task_id].to_i,
            summary: summary,
            started_at: meta[:started_at],
            ended_at: meta[:ended_at],
            status: status,
            has_branches: has_branches,
            change_count: task_change_count(task_id),
          }
        end

        tasks
      end

      # Extract text from message content (handles both string and array formats)
      private def extract_message_text(content)
        if content.is_a?(String)
          content
        elsif content.is_a?(Array)
          text_parts = content.select { |part| part[:type] == "text" }
          text_parts.map { |part| part[:text] }.join(" ")
        else
          ""
        end
      end
    end
  end
end
