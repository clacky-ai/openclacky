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
          user: [:bright_black, :bright_black],      # User prompt and input - subtle, works on both backgrounds
          assistant: [:bright_green, :bright_black], # AI response - keep green hacker style
          tool_call: [:bright_cyan, :cyan],          # Tool execution
          tool_result: [:bright_cyan, :bright_black], # Tool output
          tool_denied: [:bright_yellow, :yellow],    # Denied actions
          tool_planned: [:bright_cyan, :cyan],       # Planned actions
          tool_error: [:bright_red, :red],           # Errors
          thinking: [:bright_black, :bright_black],  # Thinking status - changed from :dim
          working: [:bright_yellow, :yellow],        # Working status
          success: [:bright_green, :green],          # Success messages
          error: [:bright_red, :red],                # Error messages
          warning: [:bright_yellow, :yellow],        # Warnings
          info: [:bright_black, :bright_black],      # Info messages - subtle
          task: [:bright_yellow, :bright_black],     # Task items
          progress: [:bright_cyan, :cyan],           # Progress indicators
          file: [:cyan, :bright_black],              # File references
          command: [:cyan, :bright_black],           # Command references
          cached: [:cyan, :cyan],                    # Cached indicators
          # Status bar colors
          statusbar_path: [:bright_black, :bright_black],        # Path - subtle
          statusbar_secondary: [:bright_black, :bright_black]   # Model/tasks/cost - subtle
        }.freeze

        def name
          "hacker"
        end
      end
    end
  end
end
