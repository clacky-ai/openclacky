# frozen_string_literal: true

require_relative "event_bus"
require_relative "layout_manager"
require_relative "view_renderer"
require_relative "components/output_area"
require_relative "components/input_area"
require_relative "components/todo_area"
require_relative "components/welcome_banner"
require_relative "components/inline_input"

module Clacky
  module UI2
    # UIController is the MVC controller layer that coordinates UI state and user interactions
    class UIController
      attr_reader :event_bus, :layout, :renderer, :running, :inline_input
      attr_accessor :config

      def initialize(config = {})
        @event_bus = EventBus.new
        @renderer = ViewRenderer.new

        # Set theme if specified
        ThemeManager.set_theme(config[:theme]) if config[:theme]

        # Store configuration
        @config = {
          working_dir: config[:working_dir],
          mode: config[:mode],
          max_iterations: config[:max_iterations],
          max_cost: config[:max_cost],
          model: config[:model],
          theme: config[:theme]
        }

        # Initialize layout components
        @output_area = Components::OutputArea.new(height: 20) # Will be recalculated
        @input_area = Components::InputArea.new
        @todo_area = Components::TodoArea.new
        @welcome_banner = Components::WelcomeBanner.new
        @inline_input = nil  # Created when needed
        @layout = LayoutManager.new(
          output_area: @output_area,
          input_area: @input_area,
          todo_area: @todo_area
        )

        @running = false
        @input_callback = nil
        @agent_thread = nil
        @tasks_count = 0
        @total_cost = 0.0

        setup_default_event_listeners
      end

      # Start the UI controller
      def start
        @running = true

        # Set session bar data before initializing screen
        @input_area.update_sessionbar(
          working_dir: @config[:working_dir],
          mode: @config[:mode],
          model: @config[:model],
          tasks: @tasks_count,
          cost: @total_cost
        )

        @layout.initialize_screen

        # Display welcome banner
        display_welcome_banner

        # Start input loop in main thread
        input_loop
      end

      # Update session bar with current stats
      # @param tasks [Integer] Number of completed tasks (optional)
      # @param cost [Float] Total cost (optional)
      def update_sessionbar(tasks: nil, cost: nil)
        @tasks_count = tasks if tasks
        @total_cost = cost if cost
        @input_area.update_sessionbar(
          working_dir: @config[:working_dir],
          mode: @config[:mode],
          model: @config[:model],
          tasks: @tasks_count,
          cost: @total_cost
        )
        @layout.render_input
      end

      # Stop the UI controller
      def stop
        @running = false
        @layout.cleanup_screen
      end

      # Set callback for user input
      # @param block [Proc] Callback to execute with user input
      def on_input(&block)
        @input_callback = block
      end

      # Append output to the output area
      # @param content [String] Content to append
      def append_output(content)
        @layout.append_output(content)
      end

      # Update the last line in output area (for progress indicator)
      # @param content [String] Content to update
      def update_progress_line(content)
        @layout.update_last_line(content)
      end

      # Clear the progress line (remove last line)
      def clear_progress_line
        @layout.remove_last_line
      end

      # Update todos display
      # @param todos [Array<Hash>] Array of todo items
      def update_todos(todos)
        @layout.update_todos(todos)
      end

      private

      # Setup default event listeners for common events
      def setup_default_event_listeners
        # User message event
        @event_bus.on(:user_message) do |data|
          output = @renderer.render_user_message(data[:content], timestamp: data[:timestamp])
          append_output(output)
        end

        # Assistant message event
        @event_bus.on(:assistant_message) do |data|
          output = @renderer.render_assistant_message(data[:content], timestamp: data[:timestamp])
          append_output(output)
        end

        # Tool call event
        @event_bus.on(:tool_call) do |data|
          output = @renderer.render_tool_call(
            tool_name: data[:tool_name],
            formatted_call: data[:formatted_call]
          )
          append_output(output)
        end

        # Tool result event
        @event_bus.on(:tool_result) do |data|
          output = @renderer.render_tool_result(result: data[:result])
          append_output(output)
        end

        # Tool error event
        @event_bus.on(:tool_error) do |data|
          output = @renderer.render_tool_error(error: data[:error])
          append_output(output)
        end
      end

      # Display welcome banner with logo and agent info
      def display_welcome_banner
        content = @welcome_banner.render_full(
          working_dir: @config[:working_dir],
          mode: @config[:mode],
          max_iterations: @config[:max_iterations],
          max_cost: @config[:max_cost]
        )
        append_output(content)
      end

      # Main input loop
      def input_loop
        @layout.screen.enable_raw_mode

        while @running
          key = @layout.screen.read_key(timeout: 0.1)
          next unless key

          handle_key(key)
        end
      rescue => e
        stop
        raise e
      ensure
        @layout.screen.disable_raw_mode
      end

      # Handle keyboard input - delegate to InputArea or InlineInput
      # @param key [Symbol, String] Key input
      def handle_key(key)
        # If InlineInput is active, delegate to it
        if @inline_input&.active?
          handle_inline_input_key(key)
          return
        end

        result = @input_area.handle_key(key)

        # Handle height change first
        if result[:height_changed]
          @layout.recalculate_layout
        end

        # Handle actions
        case result[:action]
        when :submit
          handle_submit(result[:data])
        when :exit
          stop
          exit(0)
        when :interrupt
          # Kill agent thread if running
          if @agent_thread&.alive?
            @agent_thread.raise(Interrupt, "User interrupted")
            @agent_thread = nil
          end
          @event_bus.publish(:interrupt_requested, {})
        when :clear_output
          @output_area.clear
          @layout.render_all
        when :scroll_up
          @layout.scroll_output_up
        when :scroll_down
          @layout.scroll_output_down
        end

        # Always re-render input area after key handling
        @layout.render_input
      end

      # Handle key input for InlineInput
      def handle_inline_input_key(key)
        result = @inline_input.handle_key(key)

        case result[:action]
        when :update
          # Update the last line of output with current input
          @output_area.update_last_line(@inline_input.render)
          @layout.render_all
        when :submit, :cancel
          # InlineInput is done, will be cleaned up by InputCollector
          nil
        end
      end

      # Handle submit action
      def handle_submit(data)
        # Append the input content to output area
        @layout.append_output(data[:display]) unless data[:display].empty?

        # Publish user input event
        @event_bus.publish(:user_input, { content: data[:text], images: data[:images] })

        # Call callback in background thread
        if @input_callback
          @agent_thread = Thread.new do
            @input_callback.call(data[:text], data[:images])
          rescue Interrupt
            # Silently handle interrupt - message already shown by AgentAdapter
          rescue => e
            @layout.append_output("Error: #{e.message}")
          ensure
            @agent_thread = nil
          end
        end
      end
    end
  end
end
