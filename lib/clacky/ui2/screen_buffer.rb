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
      # @return [Symbol, String, nil] Key symbol or character
      def read_key(timeout: nil)
        char = read_char(timeout: timeout)
        return nil unless char

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

        # Handle control characters
        case char
        when "\r", "\n" then :enter
        when "\u007F", "\b" then :backspace
        when "\u0003" then :ctrl_c
        when "\u0004" then :ctrl_d
        when "\u000C" then :ctrl_l
        when "\u0015" then :ctrl_u
        when "\u0012" then :ctrl_r
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
