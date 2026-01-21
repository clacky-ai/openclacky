# frozen_string_literal: true

require_relative "screen_buffer"

module Clacky
  module UI2
    # LayoutManager manages screen layout with split areas (output area on top, input area on bottom)
    class LayoutManager
      attr_reader :screen, :output_area, :input_area, :todo_area

      def initialize(output_area:, input_area:, todo_area: nil)
        @screen = ScreenBuffer.new
        @output_area = output_area
        @input_area = input_area
        @todo_area = todo_area
        @render_mutex = Mutex.new

        calculate_layout
        setup_resize_handler
      end

      # Calculate layout dimensions based on screen size and component heights
      def calculate_layout
        todo_height = @todo_area&.height || 0
        input_height = @input_area.required_height
        gap_height = 1  # Blank line between output and input

        # Layout: output -> gap -> todo -> input (with its own separators and status)
        @output_height = screen.height - gap_height - todo_height - input_height
        @output_height = [1, @output_height].max  # Minimum 1 line for output

        @gap_row = @output_height
        @todo_row = @gap_row + gap_height
        @input_row = @todo_row + todo_height

        # Update component dimensions
        @output_area.height = @output_height
        @input_area.row = @input_row
      end

      # Recalculate layout (called when input height changes)
      def recalculate_layout
        @render_mutex.synchronize do
          old_input_row = @input_row
          calculate_layout

          # If layout changed, need to re-render
          if @input_row != old_input_row
            screen.clear_screen
            render_all_internal
          end
        end
      end

      # Render all layout areas
      def render_all
        @render_mutex.synchronize do
          render_all_internal
        end
      end

      # Render just the output area
      def render_output
        @render_mutex.synchronize do
          output_area.render(start_row: 0)
          render_gap_line
          restore_cursor_to_input
          screen.flush
        end
      end

      # Render just the input area
      def render_input
        @render_mutex.synchronize do
          input_area.render(start_row: @input_row, width: screen.width)
          screen.show_cursor
          screen.flush
        end
      end

      # Update todos and re-render
      # @param todos [Array<Hash>] Array of todo items
      def update_todos(todos)
        return unless @todo_area

        @render_mutex.synchronize do
          old_height = @todo_area.height
          @todo_area.update(todos)
          new_height = @todo_area.height

          # Recalculate layout if height changed
          if old_height != new_height
            calculate_layout
            screen.clear_screen
          end

          render_all_internal
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

      # Update the last line in output area (for progress indicator)
      # @param content [String] Content to update
      def update_last_line(content)
        output_area.update_last_line(content)
        render_output
      end

      # Remove the last line from output area
      def remove_last_line
        output_area.remove_last_line
        render_output
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

      # Internal render all (without mutex)
      def render_all_internal
        output_area.render(start_row: 0)
        render_gap_line
        render_todo_internal
        input_area.render(start_row: @input_row, width: screen.width)
        screen.show_cursor
        screen.flush
      end

      # Render blank gap line between output and input
      def render_gap_line
        screen.move_cursor(@gap_row, 0)
        screen.clear_line
      end

      # Internal todo rendering (without mutex)
      def render_todo_internal
        return unless @todo_area&.visible?

        @todo_area.render(start_row: @todo_row)
      end

      # Restore cursor to input area
      def restore_cursor_to_input
        input_area.position_cursor(@input_row)
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
