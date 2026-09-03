# frozen_string_literal: true

require_relative "base_theme"

module Clacky
  module UI2
    module Themes
      # MinimalTheme - Clean, simple symbols
      class MinimalTheme < BaseTheme
        SYMBOLS = {
          user: ">",
          assistant: "<",
          tool_call: "*",
          tool_result: "-",
          tool_denied: "!",
          tool_planned: "?",
          tool_error: "x",
          thinking: ".",
          working: ".",
          success: "+",
          error: "x",
          warning: "!",
          info: "-",
          task: "#",
          progress: ">"
        }.freeze

        COLORS = {
          # Format: [symbol_color, dark_bg_text, light_bg_text]
          user: [:bright_black, :bright_black, :black],           # User prompt and input
          assistant: [:green, :bright_white, :black],           # AI response
          tool_call: [:cyan, :cyan, :cyan],                       # Tool execution
          tool_result: [:cyan, :bright_black, :bright_black],     # Tool output
          tool_denied: [:yellow, :yellow, :yellow],               # Denied actions
          tool_planned: [:cyan, :cyan, :cyan],                    # Planned actions
          tool_error: [:red, :red, :red],                         # Errors
          thinking: [:bright_black, :bright_black, :bright_black], # Thinking status
          working: [:bright_yellow, :yellow, :yellow],            # Working status
          success: [:green, :green, :green],                      # Success messages
          error: [:red, :red, :red],                              # Error messages
          warning: [:yellow, :yellow, :yellow],                   # Warnings
          info: [:bright_black, :bright_black, :bright_black],    # Info messages
          task: [:yellow, :bright_black, :bright_black],          # Task items
          progress: [:cyan, :cyan, :cyan],                        # Progress indicators
          # Status bar colors
          statusbar_path: [:bright_black, :bright_black, :bright_black],        # Path
          statusbar_secondary: [:bright_black, :bright_black, :bright_black]    # Model/tasks/cost
        }.freeze

        def name
          "minimal"
        end
      end
    end
  end
end
