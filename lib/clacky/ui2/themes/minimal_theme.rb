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
          success: "+",
          error: "x",
          warning: "!",
          info: "-",
          task: "#",
          progress: ">"
        }.freeze

        COLORS = {
          user: [:blue, :blue],
          assistant: [:green, :white],
          tool_call: [:cyan, :cyan],
          tool_result: [:white, :white],
          tool_denied: [:yellow, :yellow],
          tool_planned: [:blue, :blue],
          tool_error: [:red, :red],
          thinking: [:dim, :dim],
          success: [:green, :green],
          error: [:red, :red],
          warning: [:yellow, :yellow],
          info: [:white, :white],
          task: [:yellow, :white],
          progress: [:cyan, :cyan]
        }.freeze

        def name
          "minimal"
        end
      end
    end
  end
end
