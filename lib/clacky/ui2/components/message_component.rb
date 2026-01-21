# frozen_string_literal: true

require_relative "base_component"

module Clacky
  module UI2
    module Components
      # MessageComponent renders user and assistant messages
      class MessageComponent < BaseComponent
        # Render a message
        # @param data [Hash] Message data
        #   - :role [String] "user" or "assistant"
        #   - :content [String] Message content
        #   - :timestamp [Time, nil] Optional timestamp
        # @return [String] Rendered message
        def render(data)
          role = data[:role]
          content = data[:content]
          timestamp = data[:timestamp]
          
          case role
          when "user"
            render_user_message(content, timestamp)
          when "assistant"
            render_assistant_message(content, timestamp)
          else
            render_system_message(content, timestamp)
          end
        end

        private

        # Render user message
        # @param content [String] Message content
        # @param timestamp [Time, nil] Optional timestamp
        # @return [String] Rendered message
        def render_user_message(content, timestamp = nil)
          symbol = format_symbol(:user)
          text = format_text(content, :user)
          time_str = timestamp ? @pastel.dim("[#{format_timestamp(timestamp)}]") : ""

          "\n#{symbol} #{text} #{time_str}".rstrip
        end

        # Render assistant message
        # @param content [String] Message content
        # @param timestamp [Time, nil] Optional timestamp
        # @return [String] Rendered message
        def render_assistant_message(content, timestamp = nil)
          return "" if content.nil? || content.empty?

          symbol = format_symbol(:assistant)
          text = format_text(content, :assistant)
          time_str = timestamp ? @pastel.dim("[#{format_timestamp(timestamp)}]") : ""

          "\n#{symbol} #{text} #{time_str}".rstrip
        end

        # Render system message
        # @param content [String] Message content
        # @param timestamp [Time, nil] Optional timestamp
        # @return [String] Rendered message
        def render_system_message(content, timestamp = nil)
          symbol = format_symbol(:info)
          text = format_text(content, :info)
          time_str = timestamp ? @pastel.dim("[#{format_timestamp(timestamp)}]") : ""

          "\n#{symbol} #{text} #{time_str}".rstrip
        end
      end
    end
  end
end
