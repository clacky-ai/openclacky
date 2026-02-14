# frozen_string_literal: true

module Clacky
  class Agent
    # Session serialization for saving and restoring agent state
    # Handles session data serialization and deserialization
    module SessionSerializer
      # Restore from a saved session
      # @param session_data [Hash] Saved session data
      def restore_session(session_data)
        @session_id = session_data[:session_id]
        @messages = session_data[:messages]
        @todos = session_data[:todos] || []  # Restore todos from session
        @iterations = session_data.dig(:stats, :total_iterations) || 0
        @total_cost = session_data.dig(:stats, :total_cost_usd) || 0.0
        @working_dir = session_data[:working_dir]
        @created_at = session_data[:created_at]
        @total_tasks = session_data.dig(:stats, :total_tasks) || 0

        # Restore cache statistics if available
        @cache_stats = session_data.dig(:stats, :cache_stats) || {
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          total_requests: 0,
          cache_hit_requests: 0
        }

        # Restore previous_total_tokens for accurate delta calculation across sessions
        @previous_total_tokens = session_data.dig(:stats, :previous_total_tokens) || 0

        # Check if the session ended with an error
        last_status = session_data.dig(:stats, :last_status)
        last_error = session_data.dig(:stats, :last_error)

        if last_status == "error" && last_error
          # Find and remove the last user message that caused the error
          # This allows the user to retry with a different prompt
          last_user_index = @messages.rindex { |m| m[:role] == "user" }
          if last_user_index
            @messages = @messages[0...last_user_index]

            # Trigger a hook to notify about the rollback
            @hooks.trigger(:session_rollback, {
              reason: "Previous session ended with error",
              error_message: last_error,
              rolled_back_message_index: last_user_index
            })
          end
        end
      end

      # Generate session data for saving
      # @param status [Symbol] Status of the last task: :success, :error, or :interrupted
      # @param error_message [String] Error message if status is :error
      # @return [Hash] Session data ready for serialization
      def to_session_data(status: :success, error_message: nil)
        # Get last real user message for preview (skip compressed system messages)
        last_user_msg = @messages.reverse.find do |m|
          m[:role] == "user" && !m[:content].to_s.start_with?("[SYSTEM]")
        end

        # Extract preview text from last user message
        last_message_preview = if last_user_msg
          content = last_user_msg[:content]
          if content.is_a?(String)
            # Truncate to 100 characters for preview
            content.length > 100 ? "#{content[0..100]}..." : content
          else
            "User message (non-string content)"
          end
        else
          "No messages"
        end

        stats_data = {
          total_tasks: @total_tasks,
          total_iterations: @iterations,
          total_cost_usd: @total_cost.round(4),
          duration_seconds: @start_time ? (Time.now - @start_time).round(2) : 0,
          last_status: status.to_s,
          cache_stats: @cache_stats,
          debug_logs: @debug_logs,
          previous_total_tokens: @previous_total_tokens
        }

        # Add error message if status is error
        stats_data[:last_error] = error_message if status == :error && error_message

        {
          session_id: @session_id,
          created_at: @created_at,
          updated_at: Time.now.iso8601,
          working_dir: @working_dir,
          todos: @todos,  # Include todos in session data
          config: {
            models: @config.models,
            permission_mode: @config.permission_mode.to_s,
            enable_compression: @config.enable_compression,
            enable_prompt_caching: @config.enable_prompt_caching,
            max_tokens: @config.max_tokens,
            verbose: @config.verbose
          },
          stats: stats_data,
          messages: @messages,
          last_user_message: last_message_preview
        }
      end

      # Get recent user messages from conversation history
      # @param limit [Integer] Number of recent user messages to retrieve (default: 5)
      # @return [Array<String>] Array of recent user message contents
      def get_recent_user_messages(limit: 5)
        # Filter messages to only include real user messages (exclude system-injected ones)
        user_messages = @messages.select do |m|
          m[:role] == "user" && !m[:system_injected]
        end

        # Extract text content from the last N user messages
        user_messages.last(limit).map do |msg|
          extract_text_from_content(msg[:content])
        end
      end

      private

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
    end
  end
end
