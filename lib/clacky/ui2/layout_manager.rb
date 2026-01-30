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
        @output_row = 0  # Track current output row position

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
          # Save old layout values before recalculating
          old_gap_row = @gap_row  # This is the old fixed_area_start
          old_input_row = @input_row

          calculate_layout

          # If layout changed, clear old fixed area and re-render at new position
          if @input_row != old_input_row
            # Clear old fixed area lines (from old gap_row to screen bottom)
            ([old_gap_row, 0].max...screen.height).each do |row|
              screen.move_cursor(row, 0)
              screen.clear_line
            end

            # Re-render fixed areas at new position
            render_fixed_areas
            screen.flush
          end
        end
      end

      # Render all layout areas
      def render_all
        @render_mutex.synchronize do
          render_all_internal
        end
      end

      # Render output area - with native scroll, just ensure input stays in place
      def render_output
        @render_mutex.synchronize do
          # Output is written directly, just need to re-render fixed areas
          render_fixed_areas
          screen.flush
        end
      end

      # Render just the input area
      def render_input
        @render_mutex.synchronize do
          # Clear and re-render entire fixed area to ensure consistency
          render_fixed_areas
          screen.flush
        end
      end

      # Position cursor for inline input in output area
      # @param inline_input [Components::InlineInput] InlineInput component
      def position_inline_input_cursor(inline_input)
        return unless inline_input

        # InlineInput renders its own visual cursor via render_line_with_cursor
        # (white background on cursor character), so we don't need terminal cursor.
        # Just hide the terminal cursor to avoid showing two cursors.
        screen.hide_cursor
        screen.flush
      end

      # Update todos and re-render
      # @param todos [Array<Hash>] Array of todo items
      def update_todos(todos)
        return unless @todo_area

        @render_mutex.synchronize do
          old_height = @todo_area.height
          old_gap_row = @gap_row

          @todo_area.update(todos)
          new_height = @todo_area.height

          # Recalculate layout if height changed
          if old_height != new_height
            calculate_layout

            # Clear old fixed area lines (from old gap_row to screen bottom)
            ([old_gap_row, 0].max...screen.height).each do |row|
              screen.move_cursor(row, 0)
              screen.clear_line
            end
          end

          # Render fixed areas at new position
          render_fixed_areas
          screen.flush
        end
      end

      # Initialize the screen (render initial content)
      def initialize_screen
        screen.clear_screen
        screen.hide_cursor
        @output_row = 0
        render_all
      end

      # Cleanup the screen (restore cursor)
      def cleanup_screen
        @render_mutex.synchronize do
          # Clear fixed areas (gap + todo + input)
          fixed_start = fixed_area_start_row
          (fixed_start...screen.height).each do |row|
            screen.move_cursor(row, 0)
            screen.clear_line
          end
          
          # Move cursor to start of a new line after last output
          # Use \r to ensure we're at column 0, then move down
          screen.move_cursor([@output_row, 0].max, 0)
          print "\r"  # Carriage return to column 0
          screen.show_cursor
          screen.flush
        end
      end

      # Clear output area (for /clear command)
      def clear_output
        @render_mutex.synchronize do
          # Clear all lines in output area (from 0 to fixed_area_start - 1)
          max_output_row = fixed_area_start_row
          (0...max_output_row).each do |row|
            screen.move_cursor(row, 0)
            screen.clear_line
          end
          # Reset output row position to start
          @output_row = 0
          # Re-render fixed areas to ensure they stay in place
          render_fixed_areas
          screen.flush
        end
      end

      # Append content to output area
      # Track current row, scroll when reaching fixed area
      # @param content [String] Content to append
      def append_output(content)
        return if content.nil?

        @render_mutex.synchronize do
          max_output_row = fixed_area_start_row - 1

          # Special handling for empty string - just add a blank line
          if content.empty?
            print "\n"
            @output_row += 1
            render_fixed_areas
            screen.flush
            return
          end

          content.split("\n").each do |line|
            # Wrap long lines to prevent display issues
            wrapped_lines = wrap_long_line(line)
            
            wrapped_lines.each do |wrapped_line|
              # If at max row, need to scroll before outputting
              if @output_row > max_output_row
                # Move to bottom of screen and print newline to trigger scroll
                screen.move_cursor(screen.height - 1, 0)
                print "\n"
                # Stay at max_output_row for next output
                @output_row = max_output_row
              end

              # Output line at current position
              screen.move_cursor(@output_row, 0)
              screen.clear_line
              output_area.append(wrapped_line)
              @output_row += 1
            end
          end

          # Re-render fixed areas at screen bottom
          render_fixed_areas
          screen.flush
        end
      end

      # Update the last line in output area (for progress indicator)
      # @param content [String] Content to update
      def update_last_line(content)
        @render_mutex.synchronize do
          # Last output line is at @output_row - 1
          last_row = [@output_row - 1, 0].max
          screen.move_cursor(last_row, 0)
          screen.clear_line
          output_area.append(content)
          render_fixed_areas
          screen.flush
        end
      end

      # Remove the last line from output area
      def remove_last_line
        @render_mutex.synchronize do
          last_row = [@output_row - 1, 0].max
          screen.move_cursor(last_row, 0)
          screen.clear_line
          @output_row = last_row if @output_row > 0
          render_fixed_areas
          screen.flush
        end
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
        old_gap_row = @gap_row

        screen.update_dimensions
        calculate_layout

        # Adjust output_row if it exceeds new max
        max_row = fixed_area_start_row - 1
        @output_row = [@output_row, max_row].min

        # Clear old fixed area lines and a few lines above (in case of terminal auto-wrap)
        # Clear from a few lines before old_gap_row to screen bottom to handle wrapped content
        clear_start = [old_gap_row - 5, 0].max  # Clear 5 lines before gap to catch wrapped content
        (clear_start...screen.height).each do |row|
          screen.move_cursor(row, 0)
          screen.clear_line
        end

        render_fixed_areas
        screen.flush
      end

      private

      # Wrap a long line into multiple lines based on terminal width
      # Considers display width of multi-byte characters (e.g., Chinese characters)
      # @param line [String] Line to wrap
      # @return [Array<String>] Array of wrapped lines
      def wrap_long_line(line)
        return [""] if line.nil? || line.empty?
        
        max_width = screen.width
        return [line] if max_width <= 0
        
        # Strip ANSI codes for width calculation
        visible_line = line.gsub(/\e\[[0-9;]*m/, '')
        
        # Check if line needs wrapping
        display_width = calculate_display_width(visible_line)
        return [line] if display_width <= max_width
        
        # Line needs wrapping - split by considering display width
        wrapped = []
        current_line = ""
        current_width = 0
        ansi_codes = []  # Track ANSI codes to carry over
        
        # Extract ANSI codes and text segments
        segments = line.split(/(\e\[[0-9;]*m)/)
        
        segments.each do |segment|
          if segment =~ /^\e\[[0-9;]*m$/
            # ANSI code - add to current codes
            ansi_codes << segment
            current_line += segment
          else
            # Text segment - process character by character
            segment.each_char do |char|
              char_width = char_display_width(char)
              
              if current_width + char_width > max_width && !current_line.empty?
                # Complete current line
                wrapped << current_line
                # Start new line with carried-over ANSI codes
                current_line = ansi_codes.join
                current_width = 0
              end
              
              current_line += char
              current_width += char_width
            end
          end
        end
        
        # Add remaining content
        wrapped << current_line unless current_line.empty? || current_line == ansi_codes.join
        
        wrapped.empty? ? [""] : wrapped
      end
      
      # Calculate display width of a single character
      # @param char [String] Single character
      # @return [Integer] Display width (1 or 2)
      def char_display_width(char)
        code = char.ord
        # East Asian Wide and Fullwidth characters take 2 columns
        if (code >= 0x1100 && code <= 0x115F) ||
           (code >= 0x2329 && code <= 0x232A) ||
           (code >= 0x2E80 && code <= 0x303E) ||
           (code >= 0x3040 && code <= 0xA4CF) ||
           (code >= 0xAC00 && code <= 0xD7A3) ||
           (code >= 0xF900 && code <= 0xFAFF) ||
           (code >= 0xFE10 && code <= 0xFE19) ||
           (code >= 0xFE30 && code <= 0xFE6F) ||
           (code >= 0xFF00 && code <= 0xFF60) ||
           (code >= 0xFFE0 && code <= 0xFFE6) ||
           (code >= 0x1F300 && code <= 0x1F9FF) ||
           (code >= 0x20000 && code <= 0x2FFFD) ||
           (code >= 0x30000 && code <= 0x3FFFD)
          2
        else
          1
        end
      end
      
      # Calculate display width of a string (considering multi-byte characters)
      # @param text [String] Text to calculate
      # @return [Integer] Display width
      def calculate_display_width(text)
        width = 0
        text.each_char do |char|
          width += char_display_width(char)
        end
        width
      end

      # Calculate fixed area height (gap + todo + input)
      def fixed_area_height
        todo_height = @todo_area&.height || 0
        input_height = @input_area.required_height
        1 + todo_height + input_height  # gap + todo + input
      end

      # Calculate the starting row for fixed areas (from screen bottom)
      def fixed_area_start_row
        screen.height - fixed_area_height
      end

      # Render fixed areas (gap, todo, input) at screen bottom
      def render_fixed_areas
        # When input is paused (InlineInput active), don't render fixed areas
        # The InlineInput is rendered inline with output
        return if input_area.paused?

        start_row = fixed_area_start_row
        gap_row = start_row
        todo_row = gap_row + 1
        input_row = todo_row + (@todo_area&.height || 0)

        # Render gap line
        screen.move_cursor(gap_row, 0)
        screen.clear_line

        # Render todo
        if @todo_area&.visible?
          @todo_area.render(start_row: todo_row)
        end

        # Render input (InputArea renders its own visual cursor via render_line_with_cursor)
        input_area.render(start_row: input_row, width: screen.width)
      end

      # Internal render all (without mutex)
      def render_all_internal
        output_area.render(start_row: 0)
        render_fixed_areas
        screen.flush
      end

      # Restore cursor to input area
      def restore_cursor_to_input
        input_row = fixed_area_start_row + 1 + (@todo_area&.height || 0)
        input_area.position_cursor(input_row)
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
