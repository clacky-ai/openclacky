# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Components
      # InputArea manages the fixed input area at the bottom of the screen
      class InputArea
        attr_accessor :height, :row
        attr_reader :input_buffer, :cursor_position

        def initialize(height:, row: 0)
          @height = height
          @row = row
          @input_buffer = String.new # Create mutable string
          @cursor_position = 0
          @history = []
          @history_index = -1
          @pastel = Pastel.new
          @prompt = "[>>] "
          @width = TTY::Screen.width
        end

        # Render the input area
        # @param start_row [Integer] Screen row to start rendering
        def render(start_row:)
          update_width
          move_cursor(start_row, 0)
          clear_line
          
          # Render prompt and input
          prompt_text = @pastel.bright_blue(@prompt)
          input_text = @pastel.white(@input_buffer)
          
          print "#{prompt_text}#{input_text}"
          
          # Position cursor at current position
          actual_cursor_col = @prompt.length + @cursor_position
          move_cursor(start_row, actual_cursor_col)
          
          flush
        end

        # Handle character input
        # @param char [String] Character to insert
        def insert_char(char)
          @input_buffer.insert(@cursor_position, char)
          @cursor_position += 1
        end

        # Handle backspace
        def backspace
          return if @cursor_position == 0
          
          @input_buffer[@cursor_position - 1] = ""
          @cursor_position -= 1
        end

        # Handle delete key
        def delete_char
          return if @cursor_position >= @input_buffer.length
          
          @input_buffer[@cursor_position] = ""
        end

        # Move cursor left
        def cursor_left
          @cursor_position = [@cursor_position - 1, 0].max
        end

        # Move cursor right
        def cursor_right
          @cursor_position = [@cursor_position + 1, @input_buffer.length].min
        end

        # Move cursor to beginning of line
        def cursor_home
          @cursor_position = 0
        end

        # Move cursor to end of line
        def cursor_end
          @cursor_position = @input_buffer.length
        end

        # Get current input content with prompt
        # @return [String] Full input line with prompt
        def current_content
          return "" if @input_buffer.empty?
          "#{@prompt}#{@input_buffer}"
        end

        # Get current input value (without prompt)
        # @return [String] Input value
        def current_value
          @input_buffer
        end

        # Submit current input and return value
        # @return [String] Submitted input value
        def submit
          value = @input_buffer.dup
          add_to_history(value) unless value.empty?
          clear
          value
        end

        # Clear input buffer
        def clear
          @input_buffer = String.new # Create mutable string
          @cursor_position = 0
          @history_index = -1
        end

        # Clear entire line (Ctrl+U)
        def clear_line_input
          @input_buffer = String.new # Create mutable string
          @cursor_position = 0
        end

        # Navigate to previous history entry
        def history_prev
          return if @history.empty?
          
          if @history_index == -1
            @history_index = @history.size - 1
          else
            @history_index = [@history_index - 1, 0].max
          end
          
          load_history_entry
        end

        # Navigate to next history entry
        def history_next
          return if @history_index == -1
          
          @history_index += 1
          
          if @history_index >= @history.size
            @history_index = -1
            @input_buffer = String.new # Create mutable string
            @cursor_position = 0
          else
            load_history_entry
          end
        end

        # Set custom prompt
        # @param prompt [String] New prompt text
        def set_prompt(prompt)
          @prompt = prompt
        end

        # Check if input is empty
        # @return [Boolean] True if no input
        def empty?
          @input_buffer.empty?
        end

        private

        # Add entry to history
        # @param entry [String] Input to add to history
        def add_to_history(entry)
          @history << entry
          # Keep history size manageable (last 100 entries)
          @history = @history.last(100) if @history.size > 100
        end

        # Load history entry at current index
        def load_history_entry
          return unless @history_index >= 0 && @history_index < @history.size
          
          @input_buffer = @history[@history_index].dup
          @cursor_position = @input_buffer.length
        end

        # Update width on resize
        def update_width
          @width = TTY::Screen.width
        end

        # Move cursor to position
        def move_cursor(row, col)
          print "\e[#{row + 1};#{col + 1}H"
        end

        # Clear current line
        def clear_line
          print "\e[2K"
        end

        # Flush output
        def flush
          $stdout.flush
        end
      end
    end
  end
end
