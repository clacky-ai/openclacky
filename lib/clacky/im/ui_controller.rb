# frozen_string_literal: true

module Clacky
  module IM
    # UI controller for IM platforms.
    # Implements UIInterface with message buffering and formatting for chat adapters.
    class UIController
      include Clacky::UIInterface

      BUFFER_FLUSH_SIZE = 5  # Flush buffer when it reaches this many items

      attr_reader :platform, :chat_id

      def initialize(platform:, chat_id:, adapter:)
        @platform = platform
        @chat_id = chat_id
        @adapter = adapter
        @buffer = []
        @current_streaming_msg_id = nil
      end

      # === Output display ===

      def show_assistant_message(content)
        return if content.nil? || content.to_s.strip.empty?

        flush_buffer
        send_text(content)
        @current_streaming_msg_id = nil
      end

      def show_tool_call(name, args)
        @buffer << "⚙️ `#{summarize_tool(name, args)}`"
        flush_buffer_if_large
      end

      def show_tool_result(result)
        # Silently ignore tool results to avoid noise
      end

      def show_tool_error(error)
        msg = error.is_a?(Exception) ? error.message : error.to_s
        send_text("❌ Tool error: #{msg}")
      end

      def show_file_write_preview(path, is_new_file:)
        action = is_new_file ? "create" : "overwrite"
        @buffer << "📝 #{action}: `#{path}`"
        flush_buffer_if_large
      end

      def show_file_edit_preview(path)
        @buffer << "✏️ edit: `#{path}`"
        flush_buffer_if_large
      end

      def show_shell_preview(command)
        @buffer << "🔧 `#{command}`"
        flush_buffer_if_large
      end

      def show_file_error(error_message)
        send_text("❌ File error: #{error_message}")
      end

      def show_diff(old_content, new_content, max_lines: 50)
        # Skip diff display in IM to avoid clutter
      end

      def show_token_usage(token_data)
        # Skip token usage in IM
      end

      def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false)
        flush_buffer
        parts = ["✅ Complete"]
        parts << "#{iterations} iteration#{'s' if iterations != 1}"
        parts << "$#{cost.round(4)}" if cost && cost > 0
        parts << "#{duration.round(1)}s" if duration
        send_text(parts.join(" • "))
      end

      def append_output(content)
        return if content.nil? || content.to_s.strip.empty?
        send_text(content)
      end

      # === Status messages ===

      def show_info(message, prefix_newline: true)
        send_text("ℹ️ #{message}")
      end

      def show_warning(message)
        send_text("⚠️ #{message}")
      end

      def show_error(message)
        send_text("❌ #{message}")
      end

      def show_success(message)
        send_text("✅ #{message}")
      end

      def log(message, level: :info)
        # Only show errors and warnings in IM
        level = level.to_sym
        return unless %i[error warn warning].include?(level)

        prefix = level == :error ? "❌" : "⚠️"
        send_text("#{prefix} #{message}")
      end

      # === Progress ===

      def show_progress(message = nil, prefix_newline: true, output_buffer: nil)
        text = "⏳ #{message || 'Working...'}"

        if @adapter.supports_message_updates? && @current_streaming_msg_id
          # Update existing progress message
          @adapter.update_message(@chat_id, @current_streaming_msg_id, text)
        else
          # Send new progress message
          result = @adapter.send_text(@chat_id, text)
          @current_streaming_msg_id = result[:message_id] if result
        end
      rescue => e
        # Silently ignore progress update errors
      end

      def clear_progress
        # Progress message will be replaced by final response
        @current_streaming_msg_id = nil
      end

      # === State updates (no-ops for IM) ===

      def update_sessionbar(tasks: nil, cost: nil, status: nil); end
      def update_todos(todos); end
      def set_working_status; end
      def set_idle_status; end

      # === Blocking interaction ===

      def request_confirmation(message, default: true)
        # IM sessions run unattended — never block waiting for user input.
        # Always return the default value immediately.
        default
      end

      # === Input control (no-ops for IM) ===

      def clear_input; end
      def set_input_tips(message, type: :info); end

      # === Lifecycle ===

      def stop; end

      private

      # Send text message
      def send_text(text)
        @adapter.send_text(@chat_id, text)
      rescue => e
        warn "Failed to send message: #{e.message}"
      end

      # Flush buffered messages
      def flush_buffer
        return if @buffer.empty?

        send_text(@buffer.join("\n"))
        @buffer.clear
      end

      # Flush buffer if it's getting large
      def flush_buffer_if_large
        flush_buffer if @buffer.size >= BUFFER_FLUSH_SIZE
      end

      # Summarize tool call for display
      def summarize_tool(name, args)
        case name.to_s.downcase
        when "shell", "safe_shell"
          params = args.is_a?(String) ? JSON.parse(args) : args
          cmd = params[:command] || params["command"]
          "shell: #{cmd[0..50]}"
        when "write"
          params = args.is_a?(String) ? JSON.parse(args) : args
          path = params[:path] || params["path"]
          "write: #{path}"
        when "edit"
          params = args.is_a?(String) ? JSON.parse(args) : args
          path = params[:path] || params["path"]
          "edit: #{path}"
        when "read"
          params = args.is_a?(String) ? JSON.parse(args) : args
          path = params[:path] || params["path"]
          "read: #{path}"
        else
          name
        end
      rescue
        name
      end
    end
  end
end
