# frozen_string_literal: true

require_relative "screen_buffer"

module Clacky
  module UI2
    # LayoutManager manages screen layout with split areas (output area on top, input area on bottom)
    class LayoutManager
      attr_reader :screen, :output_area, :input_area, :separator_row

      # Layout constants
      SEPARATOR_HEIGHT = 1
      INPUT_HEIGHT = 2  # Prompt line + extra space
      STATUS_HEIGHT = 1 # Status bar height

      def initialize(output_area:, input_area:)
        @screen = ScreenBuffer.new
        @output_area = output_area
        @input_area = input_area
        @render_mutex = Mutex.new

        calculate_layout
        setup_resize_handler
      end

      # Calculate layout dimensions based on screen size
      def calculate_layout
        @output_height = screen.height - INPUT_HEIGHT - SEPARATOR_HEIGHT - STATUS_HEIGHT
        @separator_row = @output_height
        @input_row = @separator_row + SEPARATOR_HEIGHT
        @status_row = screen.height - STATUS_HEIGHT

        # Update component dimensions
        @output_area.height = @output_height
        @input_area.height = INPUT_HEIGHT
        @input_area.row = @input_row
      end

      # Render all layout areas
      def render_all
        @render_mutex.synchronize do
          output_area.render(start_row: 0)
          render_separator_internal
          input_area.render(start_row: @input_row)
          screen.show_cursor  # Show cursor in input area
        end
      end

      # Render just the output area
      def render_output
        @render_mutex.synchronize do
          output_area.render(start_row: 0)
          # Restore cursor to input area position
          restore_cursor_to_input_internal
          screen.flush
        end
      end

      # Render just the input area
      def render_input
        @render_mutex.synchronize do
          input_area.render(start_row: @input_row)
          screen.show_cursor  # Show cursor in input area
          screen.flush
        end
      end

      # Render the separator line between output and input
      def render_separator
        @render_mutex.synchronize do
          render_separator_internal
        end
      end

      # Render status bar at the bottom
      # @param status_text [String] Status text to display
      def render_status(status_text = "")
        @render_mutex.synchronize do
          screen.move_cursor(@status_row, 0)
          screen.clear_line

          require "pastel"
          pastel = Pastel.new

          # Format: [Info] Status text
          formatted = pastel.dim("[") + pastel.cyan("Info") + pastel.dim("] ") + pastel.white(status_text)
          print formatted

          # Restore cursor to input area
          restore_cursor_to_input_internal
          screen.flush
        end
      end

      # Initialize the screen (clear, hide cursor, etc.)
      def initialize_screen
        screen.enable_alt_screen
        screen.clear_screen
        screen.hide_cursor
        render_all
      end

      # Cleanup the screen (restore cursor, disable alt screen)
      def cleanup_screen
        screen.show_cursor
        screen.disable_alt_screen
      end

      # Append content to output area and re-render
      # @param content [String] Content to append
      def append_output(content)
        output_area.append(content)
        render_output
      end

      # Move input content to output area
      def move_input_to_output
        content = input_area.current_content
        return if content.empty?

        append_output(content)
        input_area.clear
        render_input
      end

      # Scroll output area up
      # @param lines [Integer] Number of lines to scroll
      def scroll_output_up(lines = 1)
        output_area.scroll_up(lines)
        render_output
      end

      # Scroll output area down
      # @param lines [Integer] Number of lines to scroll
      def scroll_output_down(lines = 1)
        output_area.scroll_down(lines)
        render_output
      end

      # Handle window resize
      def handle_resize
        screen.update_dimensions
        calculate_layout
        screen.clear_screen
        render_all
      end

      private

      # Internal separator rendering (without mutex)
      def render_separator_internal
        screen.move_cursor(@separator_row, 0)
        screen.clear_line

        require "pastel"
        pastel = Pastel.new
        separator = pastel.dim("─" * screen.width)
        print separator

        screen.flush
      end

      # Internal cursor restore (without mutex)
      def restore_cursor_to_input_internal
        prompt_length = input_area.instance_variable_get(:@prompt)&.length || 5
        cursor_col = prompt_length + input_area.cursor_position
        screen.move_cursor(@input_row, cursor_col)
        screen.show_cursor
      end

      # Setup handler for window resize
      def setup_resize_handler
        Signal.trap("WINCH") do
          handle_resize
        end
      rescue ArgumentError
        # Signal already trapped, ignore
      end
    end
  end
end
