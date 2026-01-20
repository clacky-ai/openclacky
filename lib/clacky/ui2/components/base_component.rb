# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Components
      # BaseComponent provides common functionality for all UI components
      class BaseComponent
        # Hacker-style symbols (matching existing formatter)
        SYMBOLS = {
          user: "[>>]",
          assistant: "[<<]",
          tool_call: "[=>]",
          tool_result: "[<=]",
          tool_denied: "[!!]",
          tool_planned: "[??]",
          tool_error: "[XX]",
          thinking: "[..]",
          success: "[OK]",
          error: "[ER]",
          warning: "[!!]",
          info: "[--]",
          task: "[##]",
          progress: "[>>]"
        }.freeze

        def initialize
          @pastel = Pastel.new
        end

        # Render component with given data
        # @param data [Hash] Data to render
        # @return [String] Rendered output
        def render(data)
          raise NotImplementedError, "Subclasses must implement render method"
        end

        # Class method to render without instantiating
        # @param data [Hash] Data to render
        # @return [String] Rendered output
        def self.render(data)
          new.render(data)
        end

        protected

        # Format symbol with color
        # @param symbol_key [Symbol] Symbol key from SYMBOLS
        # @param color_method [Symbol] Pastel color method
        # @return [String] Colored symbol
        def format_symbol(symbol_key, color_method = :bright_white)
          symbol = SYMBOLS[symbol_key] || "[??]"
          @pastel.public_send(color_method, symbol)
        end

        # Truncate text to max length
        # @param text [String] Text to truncate
        # @param max_length [Integer] Maximum length
        # @return [String] Truncated text
        def truncate(text, max_length)
          return "" if text.nil? || text.empty?

          cleaned = text.strip.gsub(/\s+/, ' ')
          
          if cleaned.length > max_length
            cleaned[0...max_length] + "..."
          else
            cleaned
          end
        end

        # Wrap text to specified width
        # @param text [String] Text to wrap
        # @param width [Integer] Maximum width
        # @return [Array<String>] Array of wrapped lines
        def wrap_text(text, width)
          return [] if text.nil? || text.empty?
          
          words = text.split(/\s+/)
          lines = []
          current_line = ""
          
          words.each do |word|
            if current_line.empty?
              current_line = word
            elsif (current_line.length + word.length + 1) <= width
              current_line += " #{word}"
            else
              lines << current_line
              current_line = word
            end
          end
          
          lines << current_line unless current_line.empty?
          lines
        end

        # Format timestamp
        # @param time [Time] Time object
        # @return [String] Formatted timestamp
        def format_timestamp(time = Time.now)
          time.strftime("%H:%M:%S")
        end

        # Create indented text
        # @param text [String] Text to indent
        # @param spaces [Integer] Number of spaces
        # @return [String] Indented text
        def indent(text, spaces = 2)
          prefix = " " * spaces
          text.split("\n").map { |line| "#{prefix}#{line}" }.join("\n")
        end

        # Format key-value pair
        # @param key [String] Key name
        # @param value [String] Value
        # @return [String] Formatted key-value
        def format_key_value(key, value)
          "#{@pastel.cyan(key)}: #{@pastel.white(value)}"
        end

        # Create a separator line
        # @param char [String] Character to use
        # @param width [Integer] Width of separator
        # @return [String] Separator line
        def separator(char = "─", width = 80)
          @pastel.dim(char * width)
        end

        # Format list item
        # @param text [String] Item text
        # @param bullet [String] Bullet character
        # @return [String] Formatted list item
        def format_list_item(text, bullet = "•")
          "#{@pastel.dim(bullet)} #{@pastel.white(text)}"
        end

        # Format code block
        # @param code [String] Code content
        # @param language [String, nil] Language for syntax highlighting hint
        # @return [String] Formatted code block
        def format_code_block(code, language = nil)
          header = language ? @pastel.dim("```#{language}") : @pastel.dim("```")
          footer = @pastel.dim("```")
          content = @pastel.cyan(code)
          
          "#{header}\n#{content}\n#{footer}"
        end

        # Format progress bar
        # @param current [Integer] Current value
        # @param total [Integer] Total value
        # @param width [Integer] Bar width
        # @return [String] Progress bar
        def format_progress_bar(current, total, width = 20)
          return "" if total == 0
          
          percentage = (current.to_f / total * 100).round(1)
          filled = (current.to_f / total * width).round
          empty = width - filled
          
          bar = @pastel.green("█" * filled) + @pastel.dim("░" * empty)
          "#{bar} #{percentage}%"
        end
      end
    end
  end
end
