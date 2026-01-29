# frozen_string_literal: true

require_relative "components/message_component"
require_relative "components/tool_component"
require_relative "components/common_component"
require_relative "markdown_renderer"

module Clacky
  module UI2
    # ViewRenderer coordinates all UI components and provides a unified rendering interface
    class ViewRenderer
      def initialize
        @message_component = Components::MessageComponent.new
        @tool_component = Components::ToolComponent.new
        @common_component = Components::CommonComponent.new
      end

      # Render a user message
      # @param content [String] Message content
      # @param timestamp [Time, nil] Optional timestamp
      # @return [String] Rendered message
      def render_user_message(content, timestamp: nil)
        @message_component.render(
          role: "user",
          content: content,
          timestamp: timestamp
        )
      end

      # Render an assistant message
      # @param content [String] Message content
      # @param timestamp [Time, nil] Optional timestamp
      # @return [String] Rendered message
      def render_assistant_message(content, timestamp: nil)
        # Render markdown if content contains markdown syntax
        rendered_content = if MarkdownRenderer.markdown?(content)
          MarkdownRenderer.render(content)
        else
          content
        end

        @message_component.render(
          role: "assistant",
          content: rendered_content,
          timestamp: timestamp
        )
      end

      # Render a system message
      # @param content [String] Message content
      # @param timestamp [Time, nil] Optional timestamp
      # @return [String] Rendered message
      def render_system_message(content, timestamp: nil)
        @message_component.render(
          role: "system",
          content: content,
          timestamp: timestamp
        )
      end

      # Render a tool call
      # @param tool_name [String] Tool name
      # @param formatted_call [String] Formatted call description
      # @return [String] Rendered tool call
      def render_tool_call(tool_name:, formatted_call:)
        @tool_component.render(
          type: :call,
          tool_name: tool_name,
          formatted_call: formatted_call
        )
      end

      # Render a tool result
      # @param result [String] Tool result
      # @return [String] Rendered tool result
      def render_tool_result(result:)
        @tool_component.render(
          type: :result,
          result: result
        )
      end

      # Render a tool error
      # @param error [String] Error message
      # @return [String] Rendered tool error
      def render_tool_error(error:)
        @tool_component.render(
          type: :error,
          error: error
        )
      end

      # Render a tool denied message
      # @param tool_name [String] Tool name
      # @return [String] Rendered tool denied
      def render_tool_denied(tool_name:)
        @tool_component.render(
          type: :denied,
          tool_name: tool_name
        )
      end

      # Render a tool planned message
      # @param tool_name [String] Tool name
      # @return [String] Rendered tool planned
      def render_tool_planned(tool_name:)
        @tool_component.render(
          type: :planned,
          tool_name: tool_name
        )
      end

      # Render thinking indicator
      # @return [String] Thinking indicator
      def render_thinking
        @common_component.render_thinking
      end

      # Render progress message
      # @param message [String] Progress message
      # @return [String] Progress indicator
      def render_progress(message)
        @common_component.render_progress(message)
      end

      # Render success message
      # @param message [String] Success message
      # @return [String] Success message
      def render_success(message)
        @common_component.render_success(message)
      end

      # Render error message
      # @param message [String] Error message
      # @return [String] Error message
      def render_error(message)
        @common_component.render_error(message)
      end

      # Render warning message
      # @param message [String] Warning message
      # @return [String] Warning message
      def render_warning(message)
        @common_component.render_warning(message)
      end

      # Render task completion summary
      # @param iterations [Integer] Number of iterations
      # @param cost [Float] Cost in USD
      # @param duration [Float] Duration in seconds
      # @param cache_tokens [Integer] Cache read tokens
      # @param cache_requests [Integer] Total cache requests count
      # @param cache_hits [Integer] Cache hit requests count
      # @return [String] Formatted completion summary
      def render_task_complete(iterations:, cost:, duration: nil, cache_tokens: nil, cache_requests: nil, cache_hits: nil)
        @common_component.render_task_complete(
          iterations: iterations,
          cost: cost,
          duration: duration,
          cache_tokens: cache_tokens,
          cache_requests: cache_requests,
          cache_hits: cache_hits
        )
      end

    end
  end
end
