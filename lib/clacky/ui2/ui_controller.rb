# frozen_string_literal: true

require_relative "event_bus"
require_relative "layout_manager"
require_relative "view_renderer"
require_relative "components/output_area"
require_relative "components/input_area"

module Clacky
  module UI2
    # UIController is the MVC controller layer that coordinates UI state and user interactions
    class UIController
      attr_reader :event_bus, :layout, :renderer, :running

      def initialize
        @event_bus = EventBus.new
        @renderer = ViewRenderer.new
        
        # Initialize layout components
        @output_area = Components::OutputArea.new(height: 20) # Will be recalculated
        @input_area = Components::InputArea.new(height: 2, row: 22)
        @layout = LayoutManager.new(
          output_area: @output_area,
          input_area: @input_area
        )
        
        @running = false
        @input_callback = nil
        
        setup_default_event_listeners
      end

      # Start the UI controller
      def start
        @running = true
        @layout.initialize_screen
        
        # Start input loop in main thread
        input_loop
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

      # Update status bar
      # @param text [String] Status text
      def update_status(text)
        @layout.render_status(text)
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

        # Thinking event
        @event_bus.on(:thinking) do |_data|
          output = @renderer.render_thinking
          append_output(output)
        end

        # Status update event
        @event_bus.on(:status_update) do |data|
          output = @renderer.render_status(
            iteration: data[:iteration],
            cost: data[:cost],
            tasks_completed: data[:tasks_completed],
            tasks_total: data[:tasks_total],
            message: data[:message]
          )
          update_status(output)
        end
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
        # Ensure we clean up on error
        stop
        raise e
      ensure
        @layout.screen.disable_raw_mode
      end

      # Handle keyboard input
      # @param key [Symbol, String] Key input
      def handle_key(key)
        case key
        when :enter
          handle_enter
        when :backspace
          @input_area.backspace
          @layout.render_input
        when :delete
          @input_area.delete_char
          @layout.render_input
        when :left_arrow
          @input_area.cursor_left
          @layout.render_input
        when :right_arrow
          @input_area.cursor_right
          @layout.render_input
        when :up_arrow
          handle_up_arrow
        when :down_arrow
          handle_down_arrow
        when :home
          @input_area.cursor_home
          @layout.render_input
        when :end
          @input_area.cursor_end
          @layout.render_input
        when :ctrl_c
          handle_ctrl_c
        when :ctrl_d
          handle_ctrl_d
        when :ctrl_l
          handle_ctrl_l
        when :ctrl_u
          @input_area.clear_line_input
          @layout.render_input
        when :escape
          # Ignore escape for now
        else
          # Regular character input
          if key.is_a?(String) && key.length == 1
            @input_area.insert_char(key)
            @layout.render_input
          end
        end
      end

      # Handle Enter key
      def handle_enter
        input_value = @input_area.submit
        return if input_value.empty?

        # Move input to output
        @layout.move_input_to_output

        # Publish user input event
        @event_bus.publish(:user_input, { content: input_value })

        # Call callback if set
        @input_callback&.call(input_value)
      end

      # Handle up arrow (scroll output or history)
      def handle_up_arrow
        if @input_area.empty?
          # Scroll output area
          @layout.scroll_output_up
        else
          # Navigate input history
          @input_area.history_prev
          @layout.render_input
        end
      end

      # Handle down arrow (scroll output or history)
      def handle_down_arrow
        if @input_area.empty?
          # Scroll output area
          @layout.scroll_output_down
        else
          # Navigate input history
          @input_area.history_next
          @layout.render_input
        end
      end

      # Handle Ctrl+C
      def handle_ctrl_c
        stop
        exit(0)
      end

      # Handle Ctrl+D
      def handle_ctrl_d
        if @input_area.empty?
          stop
          exit(0)
        end
      end

      # Handle Ctrl+L (clear screen)
      def handle_ctrl_l
        @output_area.clear
        @layout.render_output
      end
    end
  end
end
