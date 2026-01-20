# frozen_string_literal: true

require "pastel"
require "tempfile"

module Clacky
  module UI2
    module Components
      # InputArea manages the fixed input area at the bottom of the screen
      # Enhanced with multi-line support, image paste, and more
      class InputArea
        attr_accessor :row
        attr_reader :cursor_position, :line_index, :images, :status_message, :status_type

        def initialize(row: 0)
          @row = row
          @lines = [""]
          @line_index = 0
          @cursor_position = 0
          @history = []
          @history_index = -1
          @pastel = Pastel.new
          @prompt = "[>>] "
          @width = TTY::Screen.width

          @images = []
          @max_images = 3
          @paste_counter = 0
          @paste_placeholders = {}
          @last_ctrl_c_time = nil
          @status_message = nil
          @status_type = :info
        end

        def required_height
          height = 1  # Top separator
          height += @images.size
          height += @lines.size
          height += 1  # Bottom separator
          height += 1 if @status_message
          height
        end

        def input_buffer
          @lines.join("\n")
        end

        def handle_key(key)
          old_height = required_height

          result = case key
          when :enter then handle_enter
          when :newline then newline; { action: nil }
          when :backspace then backspace; { action: nil }
          when :delete then delete_char; { action: nil }
          when :left_arrow, :ctrl_b then cursor_left; { action: nil }
          when :right_arrow, :ctrl_f then cursor_right; { action: nil }
          when :up_arrow then handle_up_arrow
          when :down_arrow then handle_down_arrow
          when :home, :ctrl_a then cursor_home; { action: nil }
          when :end, :ctrl_e then cursor_end; { action: nil }
          when :ctrl_k then kill_to_end; { action: nil }
          when :ctrl_u then kill_to_start; { action: nil }
          when :ctrl_w then kill_word; { action: nil }
          when :ctrl_c then handle_ctrl_c
          when :ctrl_d then handle_ctrl_d
          when :ctrl_v then handle_paste
          when :escape then { action: nil }
          else
            if key.is_a?(String) && key.length >= 1 && key.ord >= 32
              insert_char(key)
            end
            { action: nil }
          end

          new_height = required_height
          if new_height != old_height
            result[:height_changed] = true
            result[:new_height] = new_height
          end

          result
        end

        def render(start_row:, width: nil)
          @width = width || TTY::Screen.width
          current_row = start_row

          render_separator(current_row)
          current_row += 1

          @images.each_with_index do |img_path, idx|
            move_cursor(current_row, 0)
            clear_line
            filename = File.basename(img_path)
            filesize = File.exist?(img_path) ? format_filesize(File.size(img_path)) : "N/A"
            print @pastel.dim("[Image #{idx + 1}] #{filename} (#{filesize}) (Ctrl+D to delete)")
            current_row += 1
          end

          @lines.each_with_index do |line, idx|
            move_cursor(current_row, 0)
            clear_line

            if idx == 0
              prompt_text = @pastel.bright_blue(@prompt)
              if idx == @line_index
                print "#{prompt_text}#{render_line_with_cursor(line)}"
              else
                print "#{prompt_text}#{@pastel.white(line)}"
              end
            else
              indent = " " * @prompt.length
              if idx == @line_index
                print "#{indent}#{render_line_with_cursor(line)}"
              else
                print "#{indent}#{@pastel.white(line)}"
              end
            end
            current_row += 1
          end

          render_separator(current_row)
          current_row += 1

          if @status_message
            move_cursor(current_row, 0)
            clear_line
            print format_status(@status_message, @status_type)
            current_row += 1
          end

          position_cursor(start_row)
          flush
        end

        def position_cursor(start_row)
          cursor_row = start_row + 1 + @images.size + @line_index
          cursor_col = @prompt.length + @cursor_position
          move_cursor(cursor_row, cursor_col)
        end

        def set_status(message, type: :info)
          @status_message = message
          @status_type = type
        end

        def clear_status
          @status_message = nil
        end

        def current_content
          text = @lines.join("\n")
          return "" if text.empty?
          "#{@prompt}#{text}"
        end

        def current_value
          expand_placeholders(@lines.join("\n"))
        end

        def empty?
          @lines.all?(&:empty?) && @images.empty?
        end

        def multiline?
          @lines.size > 1
        end

        def has_images?
          @images.any?
        end

        def set_prompt(prompt)
          @prompt = prompt
        end

        # --- Public editing methods ---

        def insert_char(char)
          chars = current_line.chars
          chars.insert(@cursor_position, char)
          @lines[@line_index] = chars.join
          @cursor_position += 1
        end

        def backspace
          if @cursor_position > 0
            chars = current_line.chars
            chars.delete_at(@cursor_position - 1)
            @lines[@line_index] = chars.join
            @cursor_position -= 1
          elsif @line_index > 0
            prev_line = @lines[@line_index - 1]
            current = @lines[@line_index]
            @lines.delete_at(@line_index)
            @line_index -= 1
            @cursor_position = prev_line.chars.length
            @lines[@line_index] = prev_line + current
          end
        end

        def delete_char
          chars = current_line.chars
          return if @cursor_position >= chars.length
          chars.delete_at(@cursor_position)
          @lines[@line_index] = chars.join
        end

        def cursor_left
          @cursor_position = [@cursor_position - 1, 0].max
        end

        def cursor_right
          @cursor_position = [@cursor_position + 1, current_line.chars.length].min
        end

        def cursor_home
          @cursor_position = 0
        end

        def cursor_end
          @cursor_position = current_line.chars.length
        end

        def clear
          @lines = [""]
          @line_index = 0
          @cursor_position = 0
          @history_index = -1
          @images = []
          @paste_counter = 0
          @paste_placeholders = {}
          clear_status
        end

        def submit
          text = current_value
          imgs = @images.dup
          add_to_history(text) unless text.empty?
          clear
          { text: text, images: imgs }
        end

        def history_prev
          return if @history.empty?
          if @history_index == -1
            @history_index = @history.size - 1
          else
            @history_index = [@history_index - 1, 0].max
          end
          load_history_entry
        end

        def history_next
          return if @history_index == -1
          @history_index += 1
          if @history_index >= @history.size
            @history_index = -1
            @lines = [""]
            @line_index = 0
            @cursor_position = 0
          else
            load_history_entry
          end
        end

        private

        def handle_enter
          text = current_value.strip

          if text.start_with?('/')
            case text
            when '/clear'
              clear
              return { action: :clear_output }
            when '/exit', '/quit'
              return { action: :exit }
            else
              set_status("Unknown command: #{text} (Available: /clear, /exit)", type: :warning)
              return { action: nil }
            end
          end

          if text.empty? && @images.empty?
            return { action: nil }
          end

          content_to_display = current_content
          result_text = current_value
          result_images = @images.dup

          add_to_history(result_text) unless result_text.empty?
          clear

          { action: :submit, data: { text: result_text, images: result_images, display: content_to_display } }
        end

        def handle_up_arrow
          if multiline?
            unless cursor_up
              history_prev
            end
          elsif empty?
            return { action: :scroll_up }
          else
            history_prev
          end
          { action: nil }
        end

        def handle_down_arrow
          if multiline?
            unless cursor_down
              history_next
            end
          elsif empty?
            return { action: :scroll_down }
          else
            history_next
          end
          { action: nil }
        end

        def handle_ctrl_c
          has_content = @lines.any? { |line| !line.strip.empty? } || @images.any?

          if has_content
            current_time = Time.now.to_f
            time_since_last = @last_ctrl_c_time ? (current_time - @last_ctrl_c_time) : Float::INFINITY

            if time_since_last < 2.0
              { action: :exit }
            else
              @last_ctrl_c_time = current_time
              clear
              { action: nil }
            end
          else
            { action: :exit }
          end
        end

        def handle_ctrl_d
          if has_images?
            if @images.size == 1
              @images.clear
            else
              @images.shift
            end
            clear_status
            { action: nil }
          elsif empty?
            { action: :exit }
          else
            { action: nil }
          end
        end

        def handle_paste
          pasted = paste_from_clipboard
          if pasted[:type] == :image
            if @images.size < @max_images
              @images << pasted[:path]
              clear_status
            else
              set_status("Maximum #{@max_images} images allowed. Delete an image first (Ctrl+D).", type: :warning)
            end
          else
            insert_text(pasted[:text])
            clear_status
          end
          { action: nil }
        end

        def insert_text(text)
          return if text.nil? || text.empty?

          text_lines = text.split(/\r\n|\r|\n/)

          if text_lines.size > 1
            @paste_counter += 1
            placeholder = "[##{@paste_counter} Paste Text]"
            @paste_placeholders[placeholder] = text

            chars = current_line.chars
            chars.insert(@cursor_position, *placeholder.chars)
            @lines[@line_index] = chars.join
            @cursor_position += placeholder.length
          else
            chars = current_line.chars
            text.chars.each_with_index do |c, i|
              chars.insert(@cursor_position + i, c)
            end
            @lines[@line_index] = chars.join
            @cursor_position += text.length
          end
        end

        def newline
          chars = current_line.chars
          @lines[@line_index] = chars[0...@cursor_position].join
          @lines.insert(@line_index + 1, chars[@cursor_position..-1]&.join || "")
          @line_index += 1
          @cursor_position = 0
        end

        def cursor_up
          return false if @line_index == 0
          @line_index -= 1
          @cursor_position = [@cursor_position, current_line.chars.length].min
          true
        end

        def cursor_down
          return false if @line_index >= @lines.size - 1
          @line_index += 1
          @cursor_position = [@cursor_position, current_line.chars.length].min
          true
        end

        def kill_to_end
          chars = current_line.chars
          @lines[@line_index] = chars[0...@cursor_position].join
        end

        def kill_to_start
          chars = current_line.chars
          @lines[@line_index] = chars[@cursor_position..-1]&.join || ""
          @cursor_position = 0
        end

        def kill_word
          chars = current_line.chars
          pos = @cursor_position - 1

          while pos >= 0 && chars[pos] =~ /\s/
            pos -= 1
          end
          while pos >= 0 && chars[pos] =~ /\S/
            pos -= 1
          end

          delete_start = pos + 1
          chars.slice!(delete_start...@cursor_position)
          @lines[@line_index] = chars.join
          @cursor_position = delete_start
        end

        def load_history_entry
          return unless @history_index >= 0 && @history_index < @history.size
          entry = @history[@history_index]
          @lines = entry.split("\n")
          @lines = [""] if @lines.empty?
          @line_index = @lines.size - 1
          @cursor_position = current_line.chars.length
        end

        def add_to_history(entry)
          @history << entry
          @history = @history.last(100) if @history.size > 100
        end

        def paste_from_clipboard
          case RbConfig::CONFIG["host_os"]
          when /darwin/i
            paste_from_clipboard_macos
          when /linux/i
            paste_from_clipboard_linux
          else
            { type: :text, text: "" }
          end
        end

        def paste_from_clipboard_macos
          has_image = system("osascript -e 'try' -e 'the clipboard as «class PNGf»' -e 'on error' -e 'return false' -e 'end try' >/dev/null 2>&1")

          if has_image
            temp_dir = Dir.tmpdir
            temp_filename = "clipboard-#{Time.now.to_i}-#{rand(10000)}.png"
            temp_path = File.join(temp_dir, temp_filename)

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

          text = `pbpaste 2>/dev/null`.to_s
          text.force_encoding('UTF-8')
          text = text.encode('UTF-8', invalid: :replace, undef: :replace)
          { type: :text, text: text }
        rescue => e
          { type: :text, text: "" }
        end

        def paste_from_clipboard_linux
          if system("which xclip >/dev/null 2>&1")
            text = `xclip -selection clipboard -o 2>/dev/null`.to_s
            text.force_encoding('UTF-8')
            text = text.encode('UTF-8', invalid: :replace, undef: :replace)
            { type: :text, text: text }
          elsif system("which xsel >/dev/null 2>&1")
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

        def current_line
          @lines[@line_index] || ""
        end

        def expand_placeholders(text)
          result = text.dup
          @paste_placeholders.each do |placeholder, actual_content|
            result.gsub!(placeholder, actual_content)
          end
          result
        end

        def render_line_with_cursor(line)
          chars = line.chars
          before_cursor = chars[0...@cursor_position].join
          cursor_char = chars[@cursor_position] || " "
          after_cursor = chars[(@cursor_position + 1)..-1]&.join || ""

          "#{@pastel.white(before_cursor)}#{@pastel.on_white(@pastel.black(cursor_char))}#{@pastel.white(after_cursor)}"
        end

        def render_separator(row)
          move_cursor(row, 0)
          clear_line
          print @pastel.dim("─" * @width)
        end

        def format_status(message, type)
          case type
          when :warning
            @pastel.dim("[") + @pastel.yellow("Warn") + @pastel.dim("] ") + @pastel.yellow(message)
          when :error
            @pastel.dim("[") + @pastel.red("Error") + @pastel.dim("] ") + @pastel.red(message)
          else
            @pastel.dim("[") + @pastel.cyan("Info") + @pastel.dim("] ") + @pastel.white(message)
          end
        end

        def format_filesize(size)
          if size < 1024
            "#{size}B"
          elsif size < 1024 * 1024
            "#{(size / 1024.0).round(1)}KB"
          else
            "#{(size / 1024.0 / 1024.0).round(1)}MB"
          end
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
