# frozen_string_literal: true

require_relative "base_component"

module Clacky
  module UI2
    module Components
      # ToolComponent renders tool calls and results
      class ToolComponent < BaseComponent
        # Render a tool event
        # @param data [Hash] Tool event data
        #   - :type [Symbol] :call, :result, :error, :denied, :planned
        #   - :tool_name [String] Name of the tool
        #   - :formatted_call [String] Formatted tool call description
        #   - :result [String] Tool result (for :result type)
        #   - :error [String] Error message (for :error type)
        # @return [String] Rendered tool event
        def render(data)
          type = data[:type]
          
          case type
          when :call
            render_tool_call(data)
          when :result
            render_tool_result(data)
          when :error
            render_tool_error(data)
          when :denied
            render_tool_denied(data)
          when :planned
            render_tool_planned(data)
          else
            render_unknown_tool_event(data)
          end
        end

        private

        # Render tool call
        # @param data [Hash] Tool call data
        # @return [String] Rendered tool call
        def render_tool_call(data)
          symbol = format_symbol(:tool_call, :bright_cyan)
          formatted_call = data[:formatted_call] || "#{data[:tool_name]}(...)"
          text = @pastel.cyan(formatted_call)
          
          "#{symbol} #{text}"
        end

        # Render tool result
        # @param data [Hash] Tool result data
        # @return [String] Rendered tool result
        def render_tool_result(data)
          symbol = format_symbol(:tool_result, :cyan)
          result = data[:result] || data[:summary] || "completed"
          text = @pastel.white(truncate(result, 200))
          
          "#{symbol} #{text}"
        end

        # Render tool error
        # @param data [Hash] Tool error data
        # @return [String] Rendered tool error
        def render_tool_error(data)
          symbol = format_symbol(:tool_error, :bright_red)
          error_msg = data[:error] || "Unknown error"
          text = @pastel.red("Error: #{error_msg}")
          
          "#{symbol} #{text}"
        end

        # Render tool denied
        # @param data [Hash] Tool denied data
        # @return [String] Rendered tool denied
        def render_tool_denied(data)
          symbol = format_symbol(:tool_denied, :bright_yellow)
          tool_name = data[:tool_name] || "unknown"
          text = @pastel.yellow("Tool denied: #{tool_name}")
          
          "#{symbol} #{text}"
        end

        # Render tool planned
        # @param data [Hash] Tool planned data
        # @return [String] Rendered tool planned
        def render_tool_planned(data)
          symbol = format_symbol(:tool_planned, :bright_blue)
          tool_name = data[:tool_name] || "unknown"
          text = @pastel.blue("Planned: #{tool_name}")
          
          "#{symbol} #{text}"
        end

        # Render unknown tool event
        # @param data [Hash] Tool event data
        # @return [String] Rendered unknown event
        def render_unknown_tool_event(data)
          symbol = format_symbol(:info, :bright_white)
          text = @pastel.white("Tool event: #{data.inspect}")
          
          "#{symbol} #{text}"
        end
      end
    end
  end
end
