# frozen_string_literal: true

require "ruby_rich"

module Clacky
  module RichUI
    module Extensions
      module ViewportSelection
        def self.apply!
          RubyRich::Viewport.class_eval do
            unless method_defined?(:clacky_handle_event_without_text_selection)
              alias_method :clacky_handle_event_without_text_selection, :handle_event

              def handle_event(event_data, layout = nil)
                return false if keyboard_event?(event_data) && !@focused

                case event_data[:name]
                when :mouse_down
                  return copy_selection if event_data[:button] == :right

                  start_scrollbar_drag(event_data, layout) || start_selection(event_data, layout)
                when :mouse_drag
                  drag_scrollbar(event_data, layout) || drag_selection(event_data, layout)
                when :mouse_up
                  stop_scrollbar_drag || clacky_stop_selection_without_copy
                else
                  clacky_handle_event_without_text_selection(event_data, layout)
                end
              end

              def clacky_stop_selection_without_copy
                return false unless @selecting

                @selecting = false
                @selected_text = extract_selected_text
                true
              end

              def copy_to_clipboard(text)
                text = text.to_s
                return false if text.empty?
                return true if RubyRich::Terminal.windows? && clacky_try_windows_clipboard(text)

                clacky_clipboard_commands.each do |command|
                  return true if clacky_write_clipboard_command(command, text)
                end

                clacky_copy_to_terminal_clipboard(text)
              end

              def copy_selection
                text = @selected_text.to_s
                return false if text.empty?

                copied = copy_to_clipboard(text)
                clacky_clear_selection if copied
                copied
              end

              def clacky_clear_selection
                @selecting = false
                @selection_start = nil
                @selection_end = nil
                @selected_text = ""
              end

              def apply_selection(line, absolute_line)
                range = normalized_selection
                return line unless range

                start_pos, end_pos = range
                return line if absolute_line < start_pos[:line] || absolute_line > end_pos[:line]

                start_col = absolute_line == start_pos[:line] ? start_pos[:col] : 0
                end_col = absolute_line == end_pos[:line] ? end_pos[:col] : display_width(strip_ansi(line).rstrip)
                end_col = [end_col, display_width(strip_ansi(line).rstrip)].min
                clacky_highlight_display_range(line, start_col, end_col)
              end

              def clacky_highlight_display_range(line, start_col, end_col)
                return line if end_col <= start_col

                result = +""
                width = 0
                active = false
                in_escape = false
                escape = +""

                line.each_char do |char|
                  if in_escape
                    escape << char
                    if char == "m"
                      result << escape
                      result << RubyRich::AnsiCode.inverse if active
                      escape = +""
                      in_escape = false
                    end
                    next
                  elsif char.ord == 27
                    escape << char
                    in_escape = true
                    next
                  end

                  char_width = Unicode::DisplayWidth.of(char)
                  should_highlight = width < end_col && width + char_width > start_col
                  if should_highlight && !active
                    result << RubyRich::AnsiCode.inverse
                    active = true
                  elsif !should_highlight && active
                    result << RubyRich::AnsiCode.reset
                    active = false
                  end
                  result << char
                  width += char_width
                end
                result << RubyRich::AnsiCode.reset if active
                result
              end

              def clacky_clipboard_commands
                commands = []
                commands << ["wl-copy"] if ENV["WAYLAND_DISPLAY"]
                if ENV["DISPLAY"]
                  commands << ["xclip", "-selection", "clipboard"]
                  commands << ["xsel", "--clipboard", "--input"]
                end
                commands << ["pbcopy"] if RUBY_PLATFORM.match?(/darwin/)
                commands
              end

              def clacky_write_clipboard_command(command, text)
                IO.popen(command, "w") { |io| io.write(text) }
                $?&.success? == true
              rescue IOError, SystemCallError
                false
              end

              def clacky_try_windows_clipboard(text)
                copy_to_windows_clipboard(text)
                true
              rescue IOError, SystemCallError
                false
              end

              def clacky_copy_to_terminal_clipboard(text)
                encoded = Base64.strict_encode64(text.encode(Encoding::UTF_8))
                $stdout.print("\e]52;c;#{encoded}\a")
                $stdout.flush
                true
              rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError, IOError, SystemCallError
                false
              end

              private :clacky_stop_selection_without_copy,
                      :copy_to_clipboard,
                      :copy_selection,
                      :clacky_clear_selection,
                      :apply_selection,
                      :clacky_highlight_display_range,
                      :clacky_clipboard_commands,
                      :clacky_write_clipboard_command,
                      :clacky_try_windows_clipboard,
                      :clacky_copy_to_terminal_clipboard
            end
          end
        end
      end
    end
  end
end
