# frozen_string_literal: true

require "tty-screen"
require "io/console"

module Clacky
  module UI2
    # ScreenBuffer manages terminal screen state and provides low-level rendering primitives
    class ScreenBuffer
      attr_reader :width, :height

      def initialize
        @width = TTY::Screen.width
        @height = TTY::Screen.height
        @buffer = []
        @last_input_time = nil
        @rapid_input_threshold = 0.01 # 10ms threshold for detecting paste-like rapid input
        setup_resize_handler
      end

      # Move cursor to specific position (0-indexed)
      # @param row [Integer] Row position
      # @param col [Integer] Column position
      def move_cursor(row, col)
        print "\e[#{row + 1};#{col + 1}H"
      end

      # Clear entire screen
      def clear_screen
        print "\e[2J"
        move_cursor(0, 0)
      end

      # Clear current line
      def clear_line
        print "\e[2K"
      end

      # Clear from cursor to end of line
      def clear_to_eol
        print "\e[K"
      end

      # Hide cursor
      def hide_cursor
        print "\e[?25l"
      end

      # Show cursor
      def show_cursor
        print "\e[?25h"
      end

      # Save cursor position
      def save_cursor
        print "\e[s"
      end

      # Restore cursor position
      def restore_cursor
        print "\e[u"
      end

      # Enable alternative screen buffer (like vim/less)
      def enable_alt_screen
        print "\e[?1049h"
      end

      # Disable alternative screen buffer
      def disable_alt_screen
        print "\e[?1049l"
      end

      # Set scroll region (DECSTBM - DEC Set Top and Bottom Margins)
      # Content written in this region will scroll, content outside will stay fixed
      # @param top [Integer] Top row (1-indexed)
      # @param bottom [Integer] Bottom row (1-indexed)
      def set_scroll_region(top, bottom)
        print "\e[#{top};#{bottom}r"
      end

      # Reset scroll region to full screen
      def reset_scroll_region
        print "\e[r"
      end

      # Scroll the scroll region up by n lines
      # @param n [Integer] Number of lines to scroll
      def scroll_up(n = 1)
        print "\e[#{n}S"
      end

      # Scroll the scroll region down by n lines
      # @param n [Integer] Number of lines to scroll
      def scroll_down(n = 1)
        print "\e[#{n}T"
      end

      # Get current screen dimensions
      def update_dimensions
        @width = TTY::Screen.width
        @height = TTY::Screen.height
      end

      # Enable raw mode (disable line buffering)
      def enable_raw_mode
        $stdin.raw!
      end

      # Disable raw mode
      def disable_raw_mode
        $stdin.cooked!
      end

      # Read a single character without echo
      # @param timeout [Float] Timeout in seconds (nil for blocking)
      # @return [String, nil] Character or nil if timeout
      def read_char(timeout: nil)
        if timeout
          return nil unless IO.select([$stdin], nil, nil, timeout)
        end
        
        $stdin.getc
      end

      # Read a key including special keys (arrows, etc.)
      # @param timeout [Float] Timeout in seconds
      # @return [Symbol, String, Hash, nil] Key symbol, character, or { type: :rapid_input, text: String }
      def read_key(timeout: nil)
        $stdin.set_encoding('UTF-8')

        current_time = Time.now.to_f
        is_rapid_input = @last_input_time && (current_time - @last_input_time) < @rapid_input_threshold
        @last_input_time = current_time

        char = read_char(timeout: timeout)
        return nil unless char

        # Ensure character is UTF-8 encoded
        char = char.force_encoding('UTF-8') if char.is_a?(String) && char.encoding != Encoding::UTF_8

        # Handle escape sequences for special keys
        if char == "\e"
          # Non-blocking read for escape sequence
          char2 = read_char(timeout: 0.01)
          return :escape unless char2

          if char2 == "["
            char3 = read_char(timeout: 0.01)
            case char3
            when "A" then return :up_arrow
            when "B" then return :down_arrow
            when "C" then return :right_arrow
            when "D" then return :left_arrow
            when "H" then return :home
            when "F" then return :end
            when "3"
              char4 = read_char(timeout: 0.01)
              return :delete if char4 == "~"
            end
          end
        end

        # Check if there are more characters available (for rapid input detection)
        has_more_input = IO.select([$stdin], nil, nil, 0)

        # If this is rapid input or there are more characters available
        if is_rapid_input || has_more_input
          buffer = char.to_s.dup
          buffer.force_encoding('UTF-8')

          # Keep reading available characters
          loop do
            break unless IO.select([$stdin], nil, nil, 0)

            next_char = $stdin.getc
            break unless next_char

            next_char = next_char.force_encoding('UTF-8') if next_char.encoding != Encoding::UTF_8
            buffer << next_char
          end

          # If we buffered multiple characters or newlines, treat as rapid input (paste)
          if buffer.length > 1 || buffer.include?("\n") || buffer.include?("\r")
            # Remove any trailing \r or \n from rapid input buffer
            cleaned_buffer = buffer.gsub(/[\r\n]+\z/, '')
            return { type: :rapid_input, text: cleaned_buffer } if cleaned_buffer.length > 0
          end

          # Single character, continue to normal handling
          char = buffer[0] if buffer.length == 1
        end

        # Handle control characters
        case char
        when "\r" then :enter
        when "\n" then :newline  # Shift+Enter sends \n
        when "\u007F", "\b" then :backspace
        when "\u0001" then :ctrl_a
        when "\u0002" then :ctrl_b
        when "\u0003" then :ctrl_c
        when "\u0004" then :ctrl_d
        when "\u0005" then :ctrl_e
        when "\u0006" then :ctrl_f
        when "\u000B" then :ctrl_k
        when "\u000C" then :ctrl_l
        when "\u0012" then :ctrl_r
        when "\u0015" then :ctrl_u
        when "\u0016" then :ctrl_v
        when "\u0017" then :ctrl_w
        else char
        end
      end

      # Flush output
      def flush
        $stdout.flush
      end

      private

      # Setup handler for terminal resize (SIGWINCH)
      def setup_resize_handler
        Signal.trap("WINCH") do
          update_dimensions
          @resize_callback&.call(@width, @height)
        end
      end

      # Register callback for resize events
      # @param block [Proc] Callback to execute on resize
      def on_resize(&block)
        @resize_callback = block
      end
    end
  end
end
