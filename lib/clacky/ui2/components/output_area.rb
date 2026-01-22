# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Components
      # OutputArea writes content directly to terminal within scroll region
      # Terminal handles scrolling natively
      class OutputArea
        attr_accessor :height

        def initialize(height:)
          @height = height
          @pastel = Pastel.new
          @width = TTY::Screen.width
          @current_row = 0  # Current row within scroll region (0-indexed)
        end

        # Append content directly to terminal (within scroll region)
        # Terminal handles scrolling automatically
        # @param content [String] Content to append (can be multi-line)
        def append(content)
          return if content.nil? || content.empty?

          update_width

          content.split("\n").each do |line|
            # Move to current position in scroll region
            move_cursor(@current_row, 0)
            clear_line
            print truncate_line(line)

            # Advance row, triggering scroll when at bottom
            if @current_row < @height - 1
              @current_row += 1
            else
              # At bottom - print newline to trigger scroll
              print "\n"
            end
          end

          flush
        end

        # Initial render - reset position
        # @param start_row [Integer] Screen row (ignored)
        def render(start_row:)
          @current_row = 0
          move_cursor(0, 0)
        end

        # Update the last line (for progress indicator)
        # @param content [String] New content for last line
        def update_last_line(content)
          # Last written line is at @current_row - 1 (or @height - 1 if at bottom)
          last_row = @current_row > 0 ? @current_row - 1 : @height - 1
          move_cursor(last_row, 0)
          clear_line
          print truncate_line(content)
          flush
        end

        # Remove the last line from output
        def remove_last_line
          last_row = @current_row > 0 ? @current_row - 1 : @height - 1
          move_cursor(last_row, 0)
          clear_line
          # Move current row back
          @current_row = last_row if @current_row > 0
          flush
        end

        # Clear - reset position
        def clear
          @current_row = 0
          move_cursor(0, 0)
        end

        # Legacy scroll methods (no-op, terminal handles scrolling)
        def scroll_up(lines = 1); end
        def scroll_down(lines = 1); end
        def scroll_to_top; end
        def scroll_to_bottom; end
        def at_bottom?; true; end
        def scroll_percentage; 0.0; end

        def visible_range
          { start: 1, end: @height, total: @height }
        end

        private

        # Truncate line to fit screen width
        def truncate_line(line)
          return "" if line.nil?

          visible_length = line.gsub(/\e\[[0-9;]*m/, "").length

          if visible_length > @width
            truncated = line[0...(@width - 3)]
            truncated + @pastel.dim("...")
          else
            line
          end
        end

        def update_width
          @width = TTY::Screen.width
        end

        def move_cursor(row, col)
          print "\e[#{row + 1};#{col + 1}H"
        end

        def clear_line
          print "\e[2K"
        end

        def flush
          $stdout.flush
        end
      end
    end
  end
end
