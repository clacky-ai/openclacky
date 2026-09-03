# frozen_string_literal: true

require_relative "base_theme"

module Clacky
  module UI2
    module Themes
      # HackerTheme - Matrix/hacker-style with bracket symbols
      class HackerTheme < BaseTheme
        SYMBOLS = {
          user: "[>>]",
          assistant: "[<<]",
          tool_call: "[=>]",
          tool_result: "[<=]",
          tool_denied: "[!!]",
          tool_planned: "[??]",
          tool_error: "[XX]",
          thinking: "[..]",
          working: "[..]",
          success: "[OK]",
          error: "[ER]",
          warning: "[!!]",
          info: "[--]",
          task: "[##]",
          progress: "[>>]",
          file: "[F]",
          command: "[C]",
          cached: "[*]"
        }.freeze

        COLORS = {
          # Format: [symbol_color, dark_bg_text, light_bg_text]
          user: [:bright_black, :white, :black],           # User prompt and input
          assistant: [:bright_green, :bright_white, :black], # AI response
          tool_call: [:bright_cyan, :cyan, :cyan],                # Tool execution
          tool_result: [:bright_cyan, :bright_black, :bright_black], # Tool output
          tool_denied: [:bright_yellow, :yellow, :yellow],        # Denied actions
          tool_planned: [:bright_cyan, :cyan, :cyan],             # Planned actions
          tool_error: [:bright_red, :red, :red],                  # Errors
          thinking: [:bright_black, :bright_black, :bright_black], # Thinking status
          working: [:bright_yellow, :yellow, :yellow],            # Working status
          success: [:bright_green, :green, :green],               # Success messages
          error: [:bright_red, :red, :red],                       # Error messages
          warning: [:bright_yellow, :yellow, :yellow],            # Warnings
          info: [:bright_black, :bright_black, :bright_black],    # Info messages
          task: [:bright_yellow, :bright_black, :bright_black],   # Task items
          progress: [:bright_cyan, :cyan, :cyan],                 # Progress indicators
          file: [:cyan, :bright_black, :bright_black],            # File references
          command: [:cyan, :bright_black, :bright_black],         # Command references
          cached: [:cyan, :cyan, :cyan],                          # Cached indicators
          # Status bar colors
          statusbar_path: [:bright_black, :bright_black, :bright_black],        # Path
          statusbar_secondary: [:bright_black, :bright_black, :bright_black]    # Model/tasks/cost
        }.freeze

        def name
          "hacker"
        end
      end
    end
  end
end
