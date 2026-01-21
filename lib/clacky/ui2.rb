# frozen_string_literal: true

# UI2 - MVC-based terminal UI system for Clacky
# Provides split-screen interface with scrollable output and fixed input

require_relative "ui2/theme_manager"
require_relative "ui2/event_bus"
require_relative "ui2/screen_buffer"
require_relative "ui2/layout_manager"
require_relative "ui2/view_renderer"
require_relative "ui2/ui_controller"
require_relative "ui2/input_collector"
require_relative "ui2/agent_adapter"

require_relative "ui2/components/base_component"
require_relative "ui2/components/output_area"
require_relative "ui2/components/input_area"
require_relative "ui2/components/message_component"
require_relative "ui2/components/tool_component"
require_relative "ui2/components/status_component"
require_relative "ui2/components/welcome_banner"

module Clacky
  module UI2
    # Version of the UI2 system
    VERSION = "1.0.0"

    # Quick start: Create a UI controller and run
    # @param config [Hash] Optional configuration (working_dir, mode, max_iterations, max_cost, model)
    # @example
    #   controller = Clacky::UI2::UIController.new
    #   controller.on_input { |input| puts "Got: #{input}" }
    #   controller.start
    def self.start(config = {}, &block)
      controller = UIController.new(config)
      controller.on_input(&block) if block_given?
      controller.start
    end
  end
end
