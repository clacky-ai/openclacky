# frozen_string_literal: true

require_relative "components/message_component"
require_relative "components/tool_component"
require_relative "components/status_component"

module Clacky
  module UI2
    # ViewRenderer coordinates all UI components and provides a unified rendering interface
    class ViewRenderer
      def initialize
        @message_component = Components::MessageComponent.new
        @tool_component = Components::ToolComponent.new
        @status_component = Components::StatusComponent.new
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
        @message_component.render(
          role: "assistant",
          content: content,
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

      # Render status information
      # @param iteration [Integer, nil] Current iteration
      # @param cost [Float, nil] Total cost
      # @param tasks_completed [Integer, nil] Completed tasks
      # @param tasks_total [Integer, nil] Total tasks
      # @param message [String, nil] Custom message
      # @return [String] Rendered status
      def render_status(iteration: nil, cost: nil, tasks_completed: nil, tasks_total: nil, message: nil)
        @status_component.render(
          iteration: iteration,
          cost: cost,
          tasks_completed: tasks_completed,
          tasks_total: tasks_total,
          message: message
        )
      end

      # Render thinking indicator
      # @return [String] Thinking indicator
      def render_thinking
        @status_component.render_thinking
      end

      # Render progress message
      # @param message [String] Progress message
      # @return [String] Progress indicator
      def render_progress(message)
        @status_component.render_progress(message)
      end

      # Render success message
      # @param message [String] Success message
      # @return [String] Success message
      def render_success(message)
        @status_component.render_success(message)
      end

      # Render error message
      # @param message [String] Error message
      # @return [String] Error message
      def render_error(message)
        @status_component.render_error(message)
      end

      # Render warning message
      # @param message [String] Warning message
      # @return [String] Warning message
      def render_warning(message)
        @status_component.render_warning(message)
      end

      # Generic render method for any component type
      # @param component_type [Symbol] Component type (:message, :tool, :status)
      # @param data [Hash] Data to render
      # @return [String] Rendered output
      def render(component_type, data)
        case component_type
        when :message
          @message_component.render(data)
        when :tool
          @tool_component.render(data)
        when :status
          @status_component.render(data)
        else
          raise ArgumentError, "Unknown component type: #{component_type}"
        end
      end
    end
  end
end
