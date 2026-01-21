# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Themes
      # BaseTheme defines the interface for all themes
      # Subclasses should override SYMBOLS and color methods
      class BaseTheme
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

        # Color schemes for different elements
        # Each returns [symbol_color, text_color]
        COLORS = {
          user: [:bright_blue, :blue],
          assistant: [:bright_green, :white],
          tool_call: [:bright_cyan, :cyan],
          tool_result: [:cyan, :white],
          tool_denied: [:bright_yellow, :yellow],
          tool_planned: [:bright_blue, :blue],
          tool_error: [:bright_red, :red],
          thinking: [:dim, :dim],
          success: [:bright_green, :green],
          error: [:bright_red, :red],
          warning: [:bright_yellow, :yellow],
          info: [:bright_white, :white],
          task: [:bright_yellow, :white],
          progress: [:bright_cyan, :cyan]
        }.freeze

        def initialize
          @pastel = Pastel.new
        end

        def symbols
          self.class::SYMBOLS
        end

        def colors
          self.class::COLORS
        end

        def symbol(key)
          symbols[key] || "[??]"
        end

        def symbol_color(key)
          colors.dig(key, 0) || :white
        end

        def text_color(key)
          colors.dig(key, 1) || :white
        end

        # Format symbol with its color
        # @param key [Symbol] Symbol key (e.g., :user, :assistant)
        # @return [String] Colored symbol
        def format_symbol(key)
          @pastel.public_send(symbol_color(key), symbol(key))
        end

        # Format text with color for given key
        # @param text [String] Text to format
        # @param key [Symbol] Color key (e.g., :user, :assistant)
        # @return [String] Colored text
        def format_text(text, key)
          @pastel.public_send(text_color(key), text)
        end

        # Theme name for display
        def name
          "base"
        end
      end
    end
  end
end
