# frozen_string_literal: true

require "io/console"
require "pastel"
require "tty-screen"
require "tempfile"
require "base64"

module Clacky
  module UI
    # Enhanced input prompt with multi-line support and image paste
    #
    # Features:
    # - Shift+Enter: Add new line
    # - Enter: Submit message
    # - Ctrl+V: Paste text or images from clipboard
    # - Image preview and management
    class EnhancedPrompt
      attr_reader :images

      def initialize
        @pastel = Pastel.new
        @formatter = Formatter.new
        @images = [] # Array of image file paths
        @paste_counter = 0 # Counter for paste operations
        @paste_placeholders = {} # Map of placeholder text to actual pasted content
        @last_input_time = nil # Track last input time for rapid input detection
        @rapid_input_threshold = 0.01 # 10ms threshold for detecting paste-like rapid input
      end

      # Read user input with enhanced features
      # @param prefix [String] Prompt prefix (default: "❯")
      # @return [Hash, nil] Returns:
      #   - { text: String, images: Array } for normal input
      #   - { command: Symbol } for commands (:clear, :exit)
      #   - nil on EOF
      def read_input(prefix: "❯")
        @images = []
        lines = []
        cursor_pos = 0
        line_index = 0
        @last_ctrl_c_time = nil  # Track when Ctrl+C was last pressed

        loop do
          # Display the prompt (simplified version)
          display_simple_prompt(lines, prefix, line_index, cursor_pos)

          # Read a single character/key
          begin
            key = read_key_with_rapid_detection
          rescue Interrupt
            return nil
          end

          # Handle buffered rapid input (system paste detection)
          if key.is_a?(Hash) && key[:type] == :rapid_input
            pasted_text = key[:text]
            pasted_lines = pasted_text.split("\n")

            if pasted_lines.size > 1
              # Multi-line rapid input - use placeholder for display
              @paste_counter += 1
              placeholder = "[##{@paste_counter} Paste Text]"
              @paste_placeholders[placeholder] = pasted_text

              # Insert placeholder at cursor position
              chars = (lines[line_index] || "").chars
              placeholder_chars = placeholder.chars
              chars.insert(cursor_pos, *placeholder_chars)
              lines[line_index] = chars.join
              cursor_pos += placeholder_chars.length
            else
              # Single line rapid input - insert at cursor (use chars for UTF-8)
              chars = (lines[line_index] || "").chars
              pasted_chars = pasted_text.chars
              chars.insert(cursor_pos, *pasted_chars)
              lines[line_index] = chars.join
              cursor_pos += pasted_chars.length
            end
            next
          end

          case key
          when "\n" # Shift+Enter - newline (Linux/Mac sends \n for Shift+Enter in some terminals)
            # Add new line
            if lines[line_index]
              # Split current line at cursor (use chars for UTF-8)
              chars = lines[line_index].chars
              lines[line_index] = chars[0...cursor_pos].join
              lines.insert(line_index + 1, chars[cursor_pos..-1].join || "")
            else
              lines.insert(line_index + 1, "")
            end
            line_index += 1
            cursor_pos = 0

          when "\r" # Enter - submit
            # Check if it's a command
            input_text = lines.join("\n").strip

            if input_text.start_with?('/')
              clear_simple_prompt(lines.size)

              # Parse command
              case input_text
              when '/clear'
                @last_display_lines = 0  # Reset so CLI messages won't be cleared
                return { command: :clear }
              when '/exit', '/quit'
                @last_display_lines = 0  # Reset before exit
                return { command: :exit }
              else
                # Unknown command - show error and continue
                @formatter.warning("Unknown command: #{input_text} (Available: /clear, /exit)")
                @last_display_lines = 0  # Reset so next display won't clear these messages
                lines = []
                cursor_pos = 0
                line_index = 0
                next
              end
            end

            # Submit if not empty
            unless input_text.empty? && @images.empty?
              clear_simple_prompt(lines.size)
              # Replace placeholders with actual pasted content
              final_text = expand_placeholders(lines.join("\n"))
              return { text: final_text, images: @images.dup }
            end

          when "\u0003" # Ctrl+C
            # Check if input is empty
            has_content = lines.any? { |line| !line.strip.empty? } || @images.any?

            if has_content
              # Input has content - clear it on first Ctrl+C
              current_time = Time.now.to_f
              time_since_last = @last_ctrl_c_time ? (current_time - @last_ctrl_c_time) : Float::INFINITY

              if time_since_last < 2.0  # Within 2 seconds of last Ctrl+C
                # Second Ctrl+C within 2 seconds - exit
                clear_simple_prompt(lines.size)
                return nil
              else
                # First Ctrl+C - clear content
                @last_ctrl_c_time = current_time
                lines = []
                @images = []
                cursor_pos = 0
                line_index = 0
                @paste_counter = 0
                @paste_placeholders = {}
              end
            else
              # Input is empty - exit immediately
              clear_simple_prompt(lines.size)
              return nil
            end

          when "\u0016" # Ctrl+V - Paste
            pasted = paste_from_clipboard
            if pasted[:type] == :image
              # Save image and add to list (max 3 images)
              if @images.size < 3
                @images << pasted[:path]
              else
                # Show warning below input box
                print "\n"
                @formatter.warning("Maximum 3 images allowed. Delete an image first (Ctrl+D).")

                # Wait a moment for user to see the message
                sleep(1.5)

                # Clear the warning lines
                print "\r\e[2K"  # Clear current line
                print "\e[1A"    # Move up one line
                print "\r\e[2K"  # Clear the warning line

                # Now clear the entire input box using the saved line count
                if @last_display_lines && @last_display_lines > 0
                  # We're now at the position where the input box ends
                  # Move up to the first line of input box
                  (@last_display_lines - 1).times do
                    print "\e[1A"
                  end
                  # Clear all lines
                  @last_display_lines.times do |i|
                    print "\r\e[2K"
                    print "\e[1B" if i < @last_display_lines - 1
                  end
                  # Move back to the first line
                  (@last_display_lines - 1).times do
                    print "\e[1A"
                  end
                  print "\r"
                end

                # Reset display state so next display will redraw
                @last_display_lines = 0
              end
            else
              # Handle pasted text
              pasted_text = pasted[:text]
              pasted_lines = pasted_text.split("\n")

              if pasted_lines.size > 1
                # Multi-line paste - use placeholder for display
                @paste_counter += 1
                placeholder = "[##{@paste_counter} Paste Text]"
                @paste_placeholders[placeholder] = pasted_text

                # Insert placeholder at cursor position
                chars = (lines[line_index] || "").chars
                placeholder_chars = placeholder.chars
                chars.insert(cursor_pos, *placeholder_chars)
                lines[line_index] = chars.join
                cursor_pos += placeholder_chars.length
              else
                # Single line paste - insert at cursor (use chars for UTF-8)
                chars = (lines[line_index] || "").chars
                pasted_chars = pasted_text.chars
                chars.insert(cursor_pos, *pasted_chars)
                lines[line_index] = chars.join
                cursor_pos += pasted_chars.length
              end
            end

          when "\u007F", "\b" # Backspace
            if cursor_pos > 0
              # Delete character before cursor (use chars for UTF-8)
              chars = (lines[line_index] || "").chars
              chars.delete_at(cursor_pos - 1)
              lines[line_index] = chars.join
              cursor_pos -= 1
            elsif line_index > 0
              # Join with previous line
              prev_line = lines[line_index - 1]
              current_line = lines[line_index]
              lines.delete_at(line_index)
              line_index -= 1
              cursor_pos = prev_line.chars.length
              lines[line_index] = prev_line + current_line
            end

          when "\e[A" # Up arrow
            if line_index > 0
              line_index -= 1
              cursor_pos = [cursor_pos, (lines[line_index] || "").chars.length].min
            end

          when "\e[B" # Down arrow
            if line_index < lines.size - 1
              line_index += 1
              cursor_pos = [cursor_pos, (lines[line_index] || "").chars.length].min
            end

          when "\e[C" # Right arrow
            current_line = lines[line_index] || ""
            cursor_pos = [cursor_pos + 1, current_line.chars.length].min

          when "\e[D" # Left arrow
            cursor_pos = [cursor_pos - 1, 0].max

          when "\u0001" # Ctrl+A - Move to beginning of line
            cursor_pos = 0

          when "\u0005" # Ctrl+E - Move to end of line
            current_line = lines[line_index] || ""
            cursor_pos = current_line.chars.length

          when "\u0006" # Ctrl+F - Move forward one character
            current_line = lines[line_index] || ""
            cursor_pos = [cursor_pos + 1, current_line.chars.length].min

          when "\u0002" # Ctrl+B - Move backward one character
            cursor_pos = [cursor_pos - 1, 0].max

          when "\u000B" # Ctrl+K - Delete from cursor to end of line
            current_line = lines[line_index] || ""
            chars = current_line.chars
            lines[line_index] = chars[0...cursor_pos].join

          when "\u0015" # Ctrl+U - Delete from beginning of line to cursor
            current_line = lines[line_index] || ""
            chars = current_line.chars
            lines[line_index] = chars[cursor_pos..-1].join || ""
            cursor_pos = 0

          when "\u0017" # Ctrl+W - Delete previous word
            current_line = lines[line_index] || ""
            chars = current_line.chars

            # Find the start of the previous word
            pos = cursor_pos - 1

            # Skip trailing whitespace
            while pos >= 0 && chars[pos] =~ /\s/
              pos -= 1
            end

            # Delete word characters
            while pos >= 0 && chars[pos] =~ /\S/
              pos -= 1
            end

            # Delete from pos+1 to cursor_pos
            delete_start = pos + 1
            chars.slice!(delete_start...cursor_pos)
            lines[line_index] = chars.join
            cursor_pos = delete_start

          when "\u0004" # Ctrl+D - Delete image by number
            if @images.any?
              # If only one image, delete it directly
              if @images.size == 1
                @images.clear

                # Clear the entire input box
                if @last_display_lines && @last_display_lines > 0
                  # Move up to the first line of input box
                  (@last_display_lines - 1).times do
                    print "\e[1A"
                  end
                  # Clear all lines
                  @last_display_lines.times do |i|
                    print "\r\e[2K"
                    print "\e[1B" if i < @last_display_lines - 1
                  end
                  # Move back to the first line
                  (@last_display_lines - 1).times do
                    print "\e[1A"
                  end
                  print "\r"
                end

                # Reset so next display starts fresh
                @last_display_lines = 0
              else
                # Multiple images - ask which one to delete
                # Move cursor to after the input box to show prompt
                print "\n"
                print "Delete image (1-#{@images.size}): "
                $stdout.flush

                # Read single character without waiting for Enter
                deleted = false
                $stdin.raw do |io|
                  char = io.getc
                  num = char.to_i

                  # Delete if valid number
                  if num > 0 && num <= @images.size
                    @images.delete_at(num - 1)
                    print "#{num} ✓"
                    deleted = true
                  else
                    print "✗"
                  end
                end

                # Clear the prompt lines
                print "\r\e[2K"  # Clear current line
                print "\e[1A"    # Move up one line
                print "\r\e[2K"  # Clear the prompt line

                # Now clear the entire input box using the saved line count
                if @last_display_lines && @last_display_lines > 0
                  # We're now at the position where the input box ends
                  # Move up to the first line of input box
                  (@last_display_lines - 1).times do
                    print "\e[1A"
                  end
                  # Clear all lines
                  @last_display_lines.times do |i|
                    print "\r\e[2K"
                    print "\e[1B" if i < @last_display_lines - 1
                  end
                  # Move back to the first line
                  (@last_display_lines - 1).times do
                    print "\e[1A"
                  end
                  print "\r"
                end

                # Reset so next display starts fresh
                @last_display_lines = 0
              end
            end

          else
            # Regular character input - support UTF-8
            if key.length >= 1 && key != "\e" && !key.start_with?("\e") && key.ord >= 32
              lines[line_index] ||= ""
              current_line = lines[line_index]

              # Insert character at cursor position (using character index, not byte index)
              chars = current_line.chars
              chars.insert(cursor_pos, key)
              lines[line_index] = chars.join
              cursor_pos += 1
            end
          end

          # Ensure we have at least one line
          lines << "" if lines.empty?
        end
      end

      private

      # Display simplified prompt (just prefix and input, no box)
      def display_simple_prompt(lines, prefix, line_index, cursor_pos)
        # Hide terminal cursor (we render our own)
        print "\e[?25l"

        # Clear previous display if exists
        if @last_display_lines && @last_display_lines > 0
          # Move up to the first line (N-1 times since we're on line N)
          (@last_display_lines - 1).times do
            print "\e[1A"  # Move up one line
          end
          # Now we're on the first line, clear all N lines
          @last_display_lines.times do |i|
            print "\r\e[2K"  # Move to beginning and clear entire line
            print "\e[1B" if i < @last_display_lines - 1  # Move down (except last line)
          end
          # Move back to the first line
          (@last_display_lines - 1).times do
            print "\e[1A"
          end
          print "\r"  # Move to beginning of line
        end

        lines_to_display = []

        # Get terminal width for full-width separator
        term_width = TTY::Screen.width

        # Top separator line (full width)
        lines_to_display << @pastel.dim("─" * term_width)

        # Show images if any
        if @images.any?
          @images.each_with_index do |img_path, idx|
            filename = File.basename(img_path)
            filesize = File.exist?(img_path) ? format_filesize(File.size(img_path)) : "N/A"
            line = @pastel.dim("[Image #{idx + 1}] #{filename} (#{filesize}) (Ctrl+D to delete)")
            lines_to_display << line
          end
        end

        # Display input lines
        display_lines = lines.empty? ? [""] : lines

        display_lines.each_with_index do |line, idx|
          if idx == 0
            # First line with prefix
            if idx == line_index
              # Show cursor on this line
              chars = line.chars
              before_cursor = chars[0...cursor_pos].join
              cursor_char = chars[cursor_pos] || " "
              after_cursor = chars[(cursor_pos + 1)..-1]&.join || ""

              line_display = "#{prefix} #{before_cursor}#{@pastel.on_white(@pastel.black(cursor_char))}#{after_cursor}"
              lines_to_display << line_display
            else
              lines_to_display << "#{prefix} #{line}"
            end
          else
            # Continuation lines (indented to align with first line content)
            indent = " " * (prefix.length + 1)
            if idx == line_index
              # Show cursor on this line
              chars = line.chars
              before_cursor = chars[0...cursor_pos].join
              cursor_char = chars[cursor_pos] || " "
              after_cursor = chars[(cursor_pos + 1)..-1]&.join || ""

              line_display = "#{indent}#{before_cursor}#{@pastel.on_white(@pastel.black(cursor_char))}#{after_cursor}"
              lines_to_display << line_display
            else
              lines_to_display << "#{indent}#{line}"
            end
          end
        end

        # Bottom separator line (full width)
        lines_to_display << @pastel.dim("─" * term_width)

        # Output all lines
        print lines_to_display.join("\n")
        print "\n"  # Move cursor to next line so clearing logic works correctly

        # Remember how many lines we displayed (including the newline)
        @last_display_lines = lines_to_display.size + 1
      end

      # Clear simple prompt display
      def clear_simple_prompt(num_lines)
        if @last_display_lines && @last_display_lines > 0
          # Move up to the first line (N-1 times since we're on line N)
          (@last_display_lines - 1).times do
            print "\e[1A"  # Move up one line
          end
          # Now we're on the first line, clear all N lines
          @last_display_lines.times do |i|
            print "\r\e[2K"  # Move to beginning and clear entire line
            print "\e[1B" if i < @last_display_lines - 1  # Move down (except last line)
          end
          # Move back to the first line
          (@last_display_lines - 1).times do
            print "\e[1A"
          end
          print "\r"  # Move to beginning of line
        end
        # Show terminal cursor again
        print "\e[?25h"
      end

      # Expand placeholders to actual pasted content
      def expand_placeholders(text)
        result = text.dup
        @paste_placeholders.each do |placeholder, actual_content|
          result.gsub!(placeholder, actual_content)
        end
        result
      end

      # Read a single key press with escape sequence handling
      # Handles UTF-8 multi-byte characters correctly
      # Also detects rapid input (paste-like behavior)
      def read_key_with_rapid_detection
        $stdin.set_encoding('UTF-8')

        current_time = Time.now.to_f
        is_rapid_input = @last_input_time && (current_time - @last_input_time) < @rapid_input_threshold
        @last_input_time = current_time

        $stdin.raw do |io|
          io.set_encoding('UTF-8')  # Ensure IO encoding is UTF-8
          c = io.getc

          # Ensure character is UTF-8 encoded
          c = c.force_encoding('UTF-8') if c.is_a?(String) && c.encoding != Encoding::UTF_8

          # Handle escape sequences (arrow keys, special keys)
          if c == "\e"
            # Read the next 2 characters for escape sequences
            begin
              extra = io.read_nonblock(2)
              extra = extra.force_encoding('UTF-8') if extra.encoding != Encoding::UTF_8
              c = c + extra
            rescue IO::WaitReadable, Errno::EAGAIN
              # No more characters available
            end
            return c
          end

          # Check if there are more characters available using IO.select with timeout 0
          has_more_input = IO.select([io], nil, nil, 0)

          # If this is rapid input or there are more characters available
          if is_rapid_input || has_more_input
            # Buffer rapid input
            buffer = c.to_s.dup
            buffer.force_encoding('UTF-8')

            # Keep reading available characters
            loop do
              begin
                next_char = io.read_nonblock(1)
                next_char = next_char.force_encoding('UTF-8') if next_char.encoding != Encoding::UTF_8
                buffer << next_char

                # Continue only if more characters are immediately available
                break unless IO.select([io], nil, nil, 0)
              rescue IO::WaitReadable, Errno::EAGAIN
                break
              end
            end

            # Ensure buffer is UTF-8
            buffer.force_encoding('UTF-8')

            # If we buffered multiple characters or newlines, treat as rapid input (paste)
            if buffer.length > 1 || buffer.include?("\n") || buffer.include?("\r")
              # Remove any trailing \r or \n from rapid input buffer
              cleaned_buffer = buffer.gsub(/[\r\n]+\z/, '')
              return { type: :rapid_input, text: cleaned_buffer } if cleaned_buffer.length > 0
            end

            # Single character rapid input, return as-is
            return buffer[0] if buffer.length == 1
          end

          c
        end
      rescue Errno::EINTR
        "\u0003" # Treat interrupt as Ctrl+C
      end

      # Legacy method for compatibility
      def read_key
        read_key_with_rapid_detection
      end

      # Paste from clipboard (cross-platform)
      # @return [Hash] { type: :text/:image, text: String, path: String }
      def paste_from_clipboard
        case RbConfig::CONFIG["host_os"]
        when /darwin/i
          paste_from_clipboard_macos
        when /linux/i
          paste_from_clipboard_linux
        when /mswin|mingw|cygwin/i
          paste_from_clipboard_windows
        else
          { type: :text, text: "" }
        end
      end

      # Paste from macOS clipboard
      def paste_from_clipboard_macos
        require 'shellwords'
        require 'fileutils'

        # First check if there's an image in clipboard
        # Use osascript to check clipboard content type
        has_image = system("osascript -e 'try' -e 'the clipboard as «class PNGf»' -e 'on error' -e 'return false' -e 'end try' >/dev/null 2>&1")

        if has_image
          # Create a persistent temporary file (won't be auto-deleted)
          temp_dir = Dir.tmpdir
          temp_filename = "clipboard-#{Time.now.to_i}-#{rand(10000)}.png"
          temp_path = File.join(temp_dir, temp_filename)

          # Extract image using osascript
          script = <<~APPLESCRIPT
            set png_data to the clipboard as «class PNGf»
            set the_file to open for access POSIX file "#{temp_path}" with write permission
            write png_data to the_file
            close access the_file
          APPLESCRIPT

          success = system("osascript", "-e", script, out: File::NULL, err: File::NULL)

          if success && File.exist?(temp_path) && File.size(temp_path) > 0
            return { type: :image, path: temp_path }
          end
        end

        # No image, try text - ensure UTF-8 encoding
        text = `pbpaste 2>/dev/null`.to_s
        text.force_encoding('UTF-8')
        # Replace invalid UTF-8 sequences with replacement character
        text = text.encode('UTF-8', invalid: :replace, undef: :replace)
        { type: :text, text: text }
      rescue => e
        # Fallback to empty text on error
        { type: :text, text: "" }
      end

      # Paste from Linux clipboard
      def paste_from_clipboard_linux
        require 'shellwords'

        # Check if xclip is available
        if system("which xclip >/dev/null 2>&1")
          # Try to get image first
          temp_file = Tempfile.new(["clipboard-", ".png"])
          temp_file.close

          # Try different image MIME types
          ["image/png", "image/jpeg", "image/jpg"].each do |mime_type|
            if system("xclip -selection clipboard -t #{mime_type} -o > #{Shellwords.escape(temp_file.path)} 2>/dev/null")
              if File.size(temp_file.path) > 0
                return { type: :image, path: temp_file.path }
              end
            end
          end

          # No image, get text - ensure UTF-8 encoding
          text = `xclip -selection clipboard -o 2>/dev/null`.to_s
          text.force_encoding('UTF-8')
          text = text.encode('UTF-8', invalid: :replace, undef: :replace)
          { type: :text, text: text }
        elsif system("which xsel >/dev/null 2>&1")
          # Fallback to xsel for text only
          text = `xsel --clipboard --output 2>/dev/null`.to_s
          text.force_encoding('UTF-8')
          text = text.encode('UTF-8', invalid: :replace, undef: :replace)
          { type: :text, text: text }
        else
          { type: :text, text: "" }
        end
      rescue => e
        { type: :text, text: "" }
      end

      # Paste from Windows clipboard
      def paste_from_clipboard_windows
        # Try to get image using PowerShell
        temp_file = Tempfile.new(["clipboard-", ".png"])
        temp_file.close

        ps_script = <<~POWERSHELL
          Add-Type -AssemblyName System.Windows.Forms
          $img = [Windows.Forms.Clipboard]::GetImage()
          if ($img) {
            $img.Save('#{temp_file.path.gsub("'", "''")}', [System.Drawing.Imaging.ImageFormat]::Png)
            exit 0
          } else {
            exit 1
          }
        POWERSHELL

        success = system("powershell", "-NoProfile", "-Command", ps_script, out: File::NULL, err: File::NULL)

        if success && File.exist?(temp_file.path) && File.size(temp_file.path) > 0
          return { type: :image, path: temp_file.path }
        end

        # No image, get text - ensure UTF-8 encoding
        text = `powershell -NoProfile -Command "Get-Clipboard" 2>nul`.to_s
        text.force_encoding('UTF-8')
        text = text.encode('UTF-8', invalid: :replace, undef: :replace)
        { type: :text, text: text }
      rescue => e
        { type: :text, text: "" }
      end

      # Format file size for display
      def format_filesize(size)
        if size < 1024
          "#{size}B"
        elsif size < 1024 * 1024
          "#{(size / 1024.0).round(1)}KB"
        else
          "#{(size / 1024.0 / 1024.0).round(1)}MB"
        end
      end
    end
  end
end
