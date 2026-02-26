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
          user: [:bright_black, :bright_black],      # User prompt and input - subtle, works on both backgrounds
          assistant: [:green, :bright_black],        # AI response
          tool_call: [:cyan, :cyan],                 # Tool execution
          tool_result: [:cyan, :bright_black],       # Tool output
          tool_denied: [:yellow, :yellow],           # Denied actions
          tool_planned: [:cyan, :cyan],              # Planned actions
          tool_error: [:red, :red],                  # Errors
          thinking: [:bright_black, :bright_black],  # Thinking status
          working: [:bright_yellow, :yellow],        # Working status
          success: [:green, :green],                 # Success messages
          error: [:red, :red],                       # Error messages
          warning: [:yellow, :yellow],               # Warnings
          info: [:bright_black, :bright_black],      # Info messages - subtle
          task: [:yellow, :bright_black],            # Task items
          progress: [:cyan, :cyan],                  # Progress indicators
          # Status bar colors
          statusbar_path: [:bright_black, :bright_black],        # Path - subtle
          statusbar_secondary: [:bright_black, :bright_black]   # Model/tasks/cost - subtle
        }.freeze

        def name
          "minimal"
        end
      end
    end
  end
end
