# frozen_string_literal: true

require 'io/console'
require 'tty-prompt'
require_relative 'base_component'

module Clacky
  module UI2
    module Components
      # ModalComponent - Displays a centered modal dialog with form fields
      class ModalComponent < BaseComponent
        attr_reader :width, :height

        def initialize
          super
          @width = 70
          @height = 16
          @title = ""
          @fields = []
          @values = {}
        end

        # Configure and show the modal
        # @param title [String] Modal title
        # @param fields [Array<Hash>] Field definitions
        # @return [Hash, nil] Hash of field values, or nil if cancelled
        def show(title:, fields:)
          @title = title
          @fields = fields
          @values = {}

          # Get terminal size
          term_height, term_width = IO.console.winsize

          # Calculate modal position (centered)
          start_row = [(term_height - @height) / 2, 1].max
          start_col = [(term_width - @width) / 2, 1].max

          begin
            # Draw modal background and border
            draw_modal(start_row, start_col)

            # Draw instructions
            draw_buttons(start_row + @height - 3, start_col)
            
            # Collect input for each field
            current_row = start_row + 3
            @fields.each do |field|
              value = collect_field_input(field, current_row, start_col)
              return nil if value == :cancelled  # User pressed Esc
              @values[field[:name]] = value
              current_row += 2
            end

            # All fields collected successfully - hide cursor
            print "\e[?25l"
            @values
          ensure
            # Clear modal area
            clear_modal(start_row, start_col)
          end
        end

        # Render method (required by BaseComponent, not used for modal)
        def render(data)
          # Modal uses interactive show() method instead
          ""
        end

        private

        # Draw the modal background and border
        private def draw_modal(start_row, start_col)
          # Use theme colors - cyan for border, bright_cyan for title
          reset = "\e[0m"

          # Draw box with border
          @height.times do |i|
            print "\e[#{start_row + i};#{start_col}H"
            
            if i == 0
              # Top border with title
              title_text = " #{@title} "
              padding = (@width - title_text.length - 2) / 2
              remaining = @width - padding - title_text.length - 2
              border_line = @pastel.cyan("┌" + "─" * padding)
              title_part = @pastel.bright_cyan(title_text)
              border_rest = @pastel.cyan("─" * remaining + "┐")
              print border_line + title_part + border_rest
            elsif i == @height - 1
              # Bottom border
              print @pastel.cyan("└" + "─" * (@width - 2) + "┘")
            else
              # Side borders with background
              left_border = @pastel.cyan("│")
              right_border = @pastel.cyan("│")
              print left_border + " " * (@width - 2) + right_border
            end
          end
        end

        # Collect input for a single field
        private def collect_field_input(field, row, col)
          require 'io/console'
          
          label_text = @pastel.white(field[:label])

          # Draw field label
          print "\e[#{row};#{col + 2}H#{label_text}"

          # Input field position
          input_row = row + 1
          input_col = col + 4
          input_width = @width - 8

          # Initialize input buffer with default value
          buffer = field[:default].to_s.dup
          cursor_pos = buffer.length
          placeholder = "Press Enter to keep current"

          # Show cursor for input
          print "\e[?25h"

          loop do
            # Draw input field with cursor or placeholder
            if buffer.empty?
              # Show placeholder in dim gray
              display_text = @pastel.dim(placeholder)
            elsif field[:mask]
              # Show masked input
              display_text = @pastel.cyan('*' * buffer.length)
            else
              # Show normal input
              display_text = @pastel.cyan(buffer)
            end
            
            # Clear line and draw input
            print "\e[#{input_row};#{input_col}H\e[K"
            print display_text
            
            # Position cursor and ensure it's visible
            visible_cursor_pos = [cursor_pos, input_width - 1].min
            print "\e[#{input_row};#{input_col + visible_cursor_pos}H"
            STDOUT.flush

            # Read character
            char = STDIN.getch

            case char
            when "\r", "\n"  # Enter - confirm input
              # Clear placeholder if input is empty
              if buffer.empty?
                print "\e[#{input_row};#{input_col}H\e[K"
              end
              # Don't hide cursor here - next field will reuse it
              return buffer
            when "\e"  # Escape sequence
              seq = STDIN.read_nonblock(2) rescue ''
              if seq.empty?
                # Just Esc key - cancel (hide cursor when cancelling)
                print "\e[?25l"
                return :cancelled
              elsif seq == '[C'  # Right arrow
                cursor_pos = [cursor_pos + 1, buffer.length].min
              elsif seq == '[D'  # Left arrow
                cursor_pos = [cursor_pos - 1, 0].max
              elsif seq == '[H'  # Home
                cursor_pos = 0
              elsif seq == '[F'  # End
                cursor_pos = buffer.length
              end
            when "\u007F", "\b"  # Backspace
              if cursor_pos > 0
                buffer[cursor_pos - 1] = ''
                cursor_pos -= 1
              end
            when "\u0003"  # Ctrl+C (hide cursor when cancelling)
              print "\e[?25l"
              return :cancelled
            when "\u0015"  # Ctrl+U - clear line
              buffer = ''
              cursor_pos = 0
            else
              # Regular character input
              if char.ord >= 32 && char.ord < 127
                buffer.insert(cursor_pos, char)
                cursor_pos += 1
              end
            end
          end
        end

        # Draw confirmation buttons
        private def draw_buttons(row, col)
          # Show instructions at bottom of modal
          buttons_text = "Press Enter after each field • Press Esc to cancel"
          button_col = col + (@width - buttons_text.length) / 2
          
          formatted = @pastel.dim(buttons_text)
          print "\e[#{row};#{button_col}H#{formatted}"
        end

        # Clear the modal area
        private def clear_modal(start_row, start_col)
          @height.times do |i|
            print "\e[#{start_row + i};#{start_col}H#{' ' * @width}"
          end
        end
      end
    end
  end
end
