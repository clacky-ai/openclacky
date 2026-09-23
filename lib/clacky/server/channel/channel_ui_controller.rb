# frozen_string_literal: true

require_relative "../../ui_interface"

module Clacky
  module Channel
    # ChannelUIController implements UIInterface for IM platform sessions.
    # It is registered as a subscriber on WebUIController so that every
    # agent output event is forwarded here and sent back to the IM platform.
    #
    # Design notes:
    # - Tool calls / results / diffs / token usage are intentionally suppressed
    #   to keep IM chat clean. Only high-signal events are forwarded.
    # - Buffering: file/shell previews accumulate in a buffer and are flushed
    #   as one message before the next assistant message, avoiding flooding.
    # - request_confirmation is not invoked directly on this class — the Web
    #   UI handles the blocking wait and only sends show_warning notifications.
    class ChannelUIController
      include Clacky::UIInterface

      BUFFER_FLUSH_SIZE = 5  # flush early when buffer is large
      PROCESS_STATUS_MAX_LENGTH = 240
      TERMINAL_PROGRESS_STATES = %i[waiting success failed interrupted].freeze
      TOOL_PROGRESS_MESSAGES = {
        "browser" => "Using the browser...",
        "edit" => "Editing a file...",
        "file_reader" => "Reading a file...",
        "glob" => "Finding files...",
        "grep" => "Searching files...",
        "invoke_skill" => "Using a skill...",
        "terminal" => "Running a command...",
        "todo_manager" => "Updating the task plan...",
        "web_fetch" => "Reading a web page...",
        "web_search" => "Searching the web...",
        "write" => "Writing a file..."
      }.freeze

      attr_reader :platform, :chat_id

      # @param event   [Hash]          inbound IM event
      # @param adapter_resolver [Proc]  callable returning the current live adapter for this platform.
      #   Using a resolver (instead of caching the adapter instance) ensures that after
      #   reload_platform replaces an adapter, in-flight sessions automatically pick up the
      #   new one — no swap/patch needed.
      # @param status_messages_resolver [Proc] callable returning true/false — whether
      #   process-status messages ("Thinking...", "Done") should be sent. Resolved
      #   per call so config changes apply without rebuilding this controller.
      # @param process_messages_resolver [Proc] callable returning true/false — whether
      #   tool-process messages (interim narration, file/shell previews) should be
      #   sent. Resolved per call so config changes apply without rebuilding.
      def initialize(event, adapter_resolver, status_messages_resolver = nil, process_messages_resolver = nil)
        @platform                 = event[:platform]
        @chat_id                  = event[:chat_id]
        @message_id               = event[:message_id]  # original message to reply under
        @adapter_resolver         = adapter_resolver
        @status_messages_resolver = status_messages_resolver
        @process_messages_resolver = process_messages_resolver
        @buffer                   = []
        @mutex                    = Mutex.new
        @progress_mutex           = Mutex.new
        @progress_id              = nil
        @progress_chat_id         = nil
        @progress_state           = nil
        @progress_history         = []
      end

      # Update the reply context for the current inbound message.
      # Called at the start of each route_message so replies are threaded correctly.
      # Also updates chat_id — a session may span multiple chats (e.g. same user
      # in both a direct message and a group), and each inbound event dictates
      # where outbound replies should be routed.
      # @param event [Hash] inbound event with :message_id and :chat_id
      def update_message_context(event)
        @mutex.synchronize do
          @message_id = event[:message_id]
          @chat_id    = event[:chat_id] if event[:chat_id]
        end
      end

      # === Output display ===

      # Start one low-frequency progress message for the current task. Platforms
      # without progress updates retain the existing standalone "Thinking..." UX.
      def start_task
        reset_progress
        return false unless status_messages?

        adapter = @adapter_resolver.call
        unless progress_updates_supported?(adapter)
          send_text("Thinking...", reply_to: nil)
          return false
        end

        chat_id, reply_to = @mutex.synchronize { [@chat_id, @message_id] }
        result = adapter.send_progress(chat_id, "Thinking...", reply_to: reply_to, state: :running)
        progress_id = result && (result[:progress_id] || result["progress_id"] ||
          result[:message_id] || result["message_id"])
        raise "Progress message did not return a progress_id" if progress_id.to_s.empty?

        @progress_mutex.synchronize do
          @progress_id = progress_id
          @progress_chat_id = chat_id
          @progress_state = :thinking
        end
        true
      rescue StandardError => e
        reset_progress
        Clacky::Logger.warn("[ChannelUI] progress card start failed", platform: @platform, error: e)
        send_text("Thinking...", reply_to: nil)
        false
      end

      # Mark an active task as interrupted. Returns true only when an in-place
      # progress update replaced the need for a separate interruption message.
      def interrupt_task
        update_active_progress("Task interrupted.", state: :interrupted)
      end

      # Forward WebUI user messages to the IM channel so both sides stay in sync.
      # Prefixed with the product/user context so it's clear who sent it.
      def show_user_message(content)
        return if content.nil? || content.to_s.strip.empty?

        send_text("[USER] #{content}")
      end

      def show_assistant_message(content, files:, interim: false, created_at: nil)
        if interim
          # Intermediate narration before a tool call. Suppressed unless
          # tool-process messages are enabled; flush pending previews first
          # so narration and its preceding previews stay in order.
          return unless process_messages?

          flush_buffer
          text = sanitize_outbound_text(content)
          send_text(text) unless text.empty? || present_process_content(text)
          return
        end

        flush_buffer
        Clacky::Logger.info("[ChannelUI] show_assistant_message files=#{files.size} content_len=#{content.to_s.length}")
        # Strip file:// markdown links from the text sent to IM channels —
        # the actual files are delivered via send_file() below, so the
        # raw markdown links would just be noise in the chat.
        text = sanitize_outbound_text(content, remove_file_links: true)
        unless text.empty?
          delivered = finalize_progress(text, state: :success)
          send_text(text) unless delivered
        end
        flush_adapter_pending
        files.each do |f|
          Clacky::Logger.info("[ChannelUI] sending file path=#{f[:path].inspect} name=#{f[:name].inspect}")
          send_file(f[:path], f[:name])
        end
      end

      def show_tool_call(name, args)
        # ask_user is the one tool that must reach the user: the agent stops and
        # waits for an answer, so swallowing it leaves the chat silently stuck.
        # Sent unconditionally — it is a question, not process noise, so the
        # process-messages toggle must not gate it.
        if Clacky::Tools::AskUser.feedback_tool?(name)
          args_data = args.is_a?(String) ? (JSON.parse(args) rescue args) : args
          questions = Clacky::Tools::AskUser.normalize_questions(args_data)
          return if questions.empty?

          context = args_data.is_a?(Hash) ? (args_data[:context] || args_data["context"]).to_s : ""
          flush_buffer
          send_text(Clacky::Tools::AskUser.render_text(questions, context))
          return
        end

        mark_task_working unless present_process_status(tool_progress_message(name))
      end

      def show_tool_result(result, ui: nil)
        # Suppress — too noisy for IM
      end

      def show_tool_error(error)
        msg = error.is_a?(Exception) ? error.message : error.to_s
        send_text("Tool error: #{msg}")
      end

      def show_tool_args(formatted_args)
        # Suppress
      end

      def show_file_write_preview(path, is_new_file:)
        action = is_new_file ? "create" : "overwrite"
        buffer_line("#{action}: #{path}")
      end

      def show_file_edit_preview(path)
        buffer_line("edit: #{path}")
      end

      def show_shell_preview(command)
        buffer_line("$ #{command}")
      end

      def show_file_error(error_message)
        send_text("File error: #{error_message}")
      end

      def show_diff(old_content, new_content, max_lines: 50)
        # Diffs are too verbose for IM — suppress
      end

      def show_token_usage(token_data)
        # Suppress
      end

      def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false, cost_source: nil, task_id: nil)
        flush_buffer
        return unless status_messages?

        if awaiting_user_feedback
          return if finalize_progress("Waiting for your response.", state: :waiting)
        end

        parts = ["Done", "#{iterations} step#{"s" if iterations != 1}"]
        # Only show cost when pricing source is known (model matched pricing table).
        # Unknown models return nil — skip to avoid misleading numbers.
        if cost && cost > 0 && cost_source
          parts << "$#{cost.round(4)}"
        end
        parts << "#{duration.round(1)}s" if duration
        return if progress_finished?
        return if finalize_progress(parts.join(" · "), state: :success)

        send_text(parts.join(" · "))
        flush_adapter_pending
      end

      def append_output(content)
        return if content.nil? || content.to_s.strip.empty?

        send_text(content)
      end

      # === Status messages ===

      def show_info(message, prefix_newline: true)
        # Suppress informational noise in IM
      end

      def show_warning(message)
        send_text("Warning: #{message}")
      end

      def show_error(message, code: nil, top_up_url: nil, raw_message: nil)
        text = "Error: #{message}"
        text += "\n#{top_up_url}" if top_up_url
        send_text(text) unless finalize_progress(text, state: :failed)
      end

      def show_success(message)
        send_text(message)
      end

      def log(message, level: :info)
        # Suppress
      end

      # === Progress ===

      def show_progress(message = nil, prefix_newline: true, output_buffer: nil)
        # Suppress — progress spinner has no IM equivalent
      end

      # === State updates (no-ops for IM) ===

      def update_sessionbar(tasks: nil, cost: nil, cost_source: nil, status: nil, latency: nil); end
      def update_todos(todos); end
      def set_working_status; end
      def set_idle_status; end

      # === Blocking interaction ===
      # Not called directly — WebUIController handles the blocking wait
      # and only notifies IM via show_warning. Implemented as auto-approve
      # as a safety fallback in case this is ever called directly.
      def request_confirmation(message, default: true)
        send_text("Confirmation requested (auto-approved): #{message}")
        default
      end

      # === Input control / lifecycle (no-ops) ===

      def clear_input; end
      def set_input_tips(message, type: :info); end
      def stop; end


      def send_text(text, reply_to: @message_id)
        text = sanitize_outbound_text(text)
        return if text.empty?

        adapter = @adapter_resolver.call
        unless adapter
          Clacky::Logger.warn("[ChannelUI] send_text: no live adapter for :#{@platform}")
          return nil
        end
        adapter.send_text(@chat_id, text, reply_to: reply_to)
      rescue StandardError => e
        Clacky::Logger.warn("[ChannelUI] send_text failed", platform: @platform, chat_id: @chat_id, error: e)
        nil
      end

      def send_file(path, name = nil)
        adapter = @adapter_resolver.call
        unless adapter
          Clacky::Logger.warn("[ChannelUI] send_file: no live adapter for :#{@platform}")
          return nil
        end
        if adapter.respond_to?(:send_file)
          adapter.send_file(@chat_id, path, name: name)
        else
          # Fallback for adapters that don't support file sending
          send_text("File: #{name || File.basename(path)}\n#{path}")
        end
      rescue StandardError => e
        Clacky::Logger.warn("[ChannelUI] send_file failed (#{@platform}/#{@chat_id}): #{e.message}")
        send_text("Failed to send file: #{File.basename(path)}\nError: #{e.message}")
      end

      private def status_messages?
        @status_messages_resolver ? @status_messages_resolver.call : false
      end

      private def process_messages?
        @process_messages_resolver ? @process_messages_resolver.call : false
      end

      private def progress_updates_supported?(adapter)
        adapter && adapter.respond_to?(:supports_progress_updates?) &&
          adapter.supports_progress_updates? &&
          adapter.respond_to?(:send_progress) && adapter.respond_to?(:update_progress)
      end

      private def mark_task_working
        progress_id = nil
        @progress_mutex.synchronize do
          progress_id = @progress_id if @progress_state == :thinking
        end
        return false unless progress_id

        update_active_progress("Working...", state: :working)
      end

      # Route compact process signals into the active progress card. Returning
      # false lets callers retain the existing standalone-message behavior on
      # adapters (or configurations) without an active progress message.
      private def present_process_status(text)
        return false unless process_messages?
        # Once the card has reached a terminal state, delayed process events
        # belong to the completed task and must not leak out as new messages.
        return true if progress_finished?

        status = compact_process_status(text)
        return false if status.empty?

        update_active_progress(status, state: :working)
      end

      private def present_process_content(text)
        return false unless process_messages?
        return true if progress_finished?

        content = sanitize_outbound_text(text)
        return false if content.empty?

        update_active_progress(
          "Working...",
          state: :working,
          content: content,
          history_entry: content
        )
      end

      private def compact_process_status(text)
        status = sanitize_outbound_text(text).gsub(/\s+/, " ")
        return status if status.length <= PROCESS_STATUS_MAX_LENGTH

        "#{status[0, PROCESS_STATUS_MAX_LENGTH - 3]}..."
      end

      private def tool_progress_message(name)
        TOOL_PROGRESS_MESSAGES.fetch(name.to_s.downcase, "Working...")
      end

      private def finalize_progress(text, state:)
        return true if progress_finished?

        updated = update_active_progress(
          text,
          state: state,
          content: text,
          include_history: true
        )
        updated || progress_finished?
      end

      private def update_active_progress(
        text,
        state:,
        content: nil,
        history_entry: nil,
        include_history: false
      )
        @progress_mutex.synchronize do
          return false unless @progress_id && @progress_chat_id
          return false if TERMINAL_PROGRESS_STATES.include?(@progress_state)

          adapter = @adapter_resolver.call
          unless progress_updates_supported?(adapter)
            clear_progress_unlocked
            return false
          end

          next_history = @progress_history.dup
          next_history << history_entry if history_entry
          history = if (history_entry || include_history) && next_history.any?
            next_history.join("\n\n")
          end

          updated = adapter.update_progress(
            @progress_chat_id,
            @progress_id,
            text,
            state: state,
            content: content,
            history: history
          )
          unless updated
            if TERMINAL_PROGRESS_STATES.include?(state)
              clear_progress_unlocked
            else
              # A transient milestone failure should not discard the native
              # card session; the final reply may still update it successfully.
              @progress_state = state
            end
            return false
          end

          @progress_state = state
          @progress_history = next_history if history_entry
          true
        end
      rescue StandardError => e
        reset_progress
        Clacky::Logger.warn("[ChannelUI] progress card update failed", platform: @platform, error: e)
        false
      end

      private def progress_finished?
        @progress_mutex.synchronize do
          !!(@progress_id && TERMINAL_PROGRESS_STATES.include?(@progress_state))
        end
      end

      private def reset_progress
        @progress_mutex.synchronize { clear_progress_unlocked }
      end

      private def clear_progress_unlocked
        @progress_id = nil
        @progress_chat_id = nil
        @progress_state = nil
        @progress_history = []
      end

      private def sanitize_outbound_text(text, remove_file_links: false)
        sanitized = text.to_s.gsub(/<think>[\s\S]*?<\/think>\n*/i, "")
        if remove_file_links
          sanitized = sanitized.gsub(/!?\[[^\]]*\]\(file:\/\/[^)]+\)/, "")
        end
        sanitized.strip
      end

      def buffer_line(line)
        return unless process_messages?
        return if present_process_status(line)

        @mutex.synchronize do
          @buffer << line
          flush_buffer_unlocked if @buffer.size >= BUFFER_FLUSH_SIZE
        end
      end

      def flush_buffer
        @mutex.synchronize { flush_buffer_unlocked }
      end

      def flush_buffer_unlocked
        return if @buffer.empty?

        send_text(@buffer.join("\n"))
        @buffer.clear
      end

      def flush_adapter_pending
        adapter = @adapter_resolver.call
        adapter.flush_pending(@chat_id) if adapter&.respond_to?(:flush_pending)
      end
    end
  end
end
