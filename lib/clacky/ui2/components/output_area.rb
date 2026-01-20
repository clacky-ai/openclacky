# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Components
      # OutputArea manages scrollable output content in the upper part of the screen
      class OutputArea
        attr_accessor :height
        attr_reader :buffer, :scroll_offset

        def initialize(height:)
          @height = height
          @buffer = []          # All output lines
          @scroll_offset = 0    # Current scroll position (0 = latest at bottom)
          @pastel = Pastel.new
          @width = TTY::Screen.width
        end

        # Append content to the buffer
        # @param content [String] Content to append (can be multi-line)
        def append(content)
          return if content.nil? || content.empty?
          
          lines = content.split("\n")
          @buffer.concat(lines)
          
          # Auto-scroll to bottom when new content arrives (only if already at bottom)
          auto_scroll_to_bottom if at_bottom?
        end

        # Render the visible portion of the buffer
        # @param start_row [Integer] Screen row to start rendering
        def render(start_row:)
          update_width
          visible_lines = get_visible_lines
          
          visible_lines.each_with_index do |line, i|
            move_cursor(start_row + i, 0)
            clear_line
            print truncate_line(line)
          end
          
          # Clear remaining lines in the output area
          (visible_lines.size...@height).each do |i|
            move_cursor(start_row + i, 0)
            clear_line
          end
          
          flush
        end

        # Scroll up (show older content)
        # @param lines [Integer] Number of lines to scroll
        def scroll_up(lines = 1)
          max_scroll = [@buffer.size - @height, 0].max
          @scroll_offset = [@scroll_offset + lines, max_scroll].min
        end

        # Scroll down (show newer content)
        # @param lines [Integer] Number of lines to scroll
        def scroll_down(lines = 1)
          @scroll_offset = [@scroll_offset - lines, 0].max
        end

        # Scroll to top of buffer
        def scroll_to_top
          @scroll_offset = [@buffer.size - @height, 0].max
        end

        # Scroll to bottom of buffer
        def scroll_to_bottom
          @scroll_offset = 0
        end

        # Clear all content
        def clear
          @buffer.clear
          @scroll_offset = 0
        end

        # Check if currently at bottom
        # @return [Boolean] True if showing the latest content
        def at_bottom?
          @scroll_offset == 0
        end

        # Get scroll percentage
        # @return [Float] Percentage scrolled (0.0 = bottom, 1.0 = top)
        def scroll_percentage
          return 0.0 if @buffer.size <= @height
          
          max_scroll = @buffer.size - @height
          (@scroll_offset.to_f / max_scroll * 100).round(1)
        end

        # Get visible line range info
        # @return [Hash] Hash with :start, :end, :total
        def visible_range
          visible_lines = get_visible_lines
          start_idx = @buffer.size - @scroll_offset - visible_lines.size
          
          {
            start: start_idx + 1,
            end: start_idx + visible_lines.size,
            total: @buffer.size
          }
        end

        private

        # Get the visible lines based on scroll offset
        # @return [Array<String>] Visible lines
        def get_visible_lines
          return [] if @buffer.empty?
          
          # Calculate the range of lines to show
          # scroll_offset = 0 means show the latest lines (bottom)
          # scroll_offset > 0 means scrolled up to show older lines
          end_idx = @buffer.size - @scroll_offset
          start_idx = [end_idx - @height, 0].max
          
          @buffer[start_idx...end_idx] || []
        end

        # Auto-scroll to bottom when new content arrives
        def auto_scroll_to_bottom
          @scroll_offset = 0
        end

        # Truncate line to fit screen width
        # @param line [String] Line to truncate
        # @return [String] Truncated line
        def truncate_line(line)
          return "" if line.nil?
          
          # Handle ANSI color codes by calculating visible length
          visible_length = line.gsub(/\e\[[0-9;]*m/, "").length
          
          if visible_length > @width
            # Truncate and add indicator
            truncated = line[0...(@width - 3)]
            truncated + @pastel.dim("...")
          else
            line
          end
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
