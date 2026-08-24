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
          text = content.to_s.strip
          send_text(text) unless text.empty?
          return
        end

        flush_buffer
        Clacky::Logger.info("[ChannelUI] show_assistant_message files=#{files.size} content_len=#{content.to_s.length}")
        # Strip file:// markdown links from the text sent to IM channels —
        # the actual files are delivered via send_file() below, so the
        # raw markdown links would just be noise in the chat.
        text = content.to_s.gsub(/!?\[[^\]]*\]\(file:\/\/[^)]+\)/, "").strip
        send_text(text) unless text.empty?
        flush_adapter_pending
        files.each do |f|
          Clacky::Logger.info("[ChannelUI] sending file path=#{f[:path].inspect} name=#{f[:name].inspect}")
          send_file(f[:path], f[:name])
        end
      end

      def show_tool_call(name, args)
        # Suppress — too noisy for IM
      end

      def show_tool_result(result)
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

      def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false, cost_source: nil)
        flush_buffer
        return unless status_messages?

        parts = ["Done", "#{iterations} step#{"s" if iterations != 1}"]
        # Only show cost when pricing source is known (model matched pricing table).
        # Unknown models return nil — skip to avoid misleading numbers.
        if cost && cost > 0 && cost_source
          parts << "$#{cost.round(4)}"
        end
        parts << "#{duration.round(1)}s" if duration
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
        send_text(text)
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


      def send_text(text)
        text = text.to_s.gsub(/<think>[\s\S]*?<\/think>\n*/i, "").strip
        return if text.empty?

        adapter = @adapter_resolver.call
        unless adapter
          Clacky::Logger.warn("[ChannelUI] send_text: no live adapter for :#{@platform}")
          return nil
        end
        adapter.send_text(@chat_id, text, reply_to: @message_id)
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

      def buffer_line(line)
        return unless process_messages?

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
