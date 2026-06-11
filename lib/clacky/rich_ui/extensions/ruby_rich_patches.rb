# frozen_string_literal: true

module RubyRich
  class Viewport
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
              result << AnsiCode.inverse if active
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
            result << AnsiCode.inverse
            active = true
          elsif !should_highlight && active
            result << AnsiCode.reset
            active = false
          end
          result << char
          width += char_width
        end
        result << AnsiCode.reset if active
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

  class Transcript
    unless private_method_defined?(:clacky_render_entry_without_plain)
      alias_method :clacky_render_entry_without_plain, :render_entry

      def render_entry(entry, index)
        if entry.metadata[:plain]
          entry.content.to_s.split("\n", -1)
        else
          clacky_render_entry_without_plain(entry, index)
        end
      end

      private :render_entry
    end
  end

  class Markdown
    class TerminalRenderer
      unless method_defined?(:clacky_fit_table_rows)
        def table(header, body)
          all_rows = @table_state[:all_rows]
          reset_table_state
          return "" if all_rows.empty?

          header_line_count = [header.to_s.strip.split("\n").size, 1].max
          header_rows = all_rows[0...header_line_count]
          body_rows = all_rows[header_line_count..] || []

          return "" if header_rows.empty? || body_rows.empty?

          headers, fitted_body_rows = clacky_fit_table_rows(header_rows.last, body_rows)
          begin
            tbl = RubyRich::Table.new(headers: headers, border_style: @options[:table_border_style] || :simple)
            fitted_body_rows.each do |row|
              padded = row + Array.new([0, headers.length - row.length].max, "")
              tbl.add_row(padded[0...headers.length])
            end
            return "#{tbl.render}\n\n"
          rescue
            # fall through to the original plain fallback shape
          end

          result = "\n"
          result += "#{header.strip}\n"
          result += "#{"-" * [header.strip.length, 20].min}\n"
          result += "#{body.strip}\n" if body && !body.strip.empty?
          "#{result}\n"
        end

        def clacky_fit_table_rows(header_row, body_rows)
          column_count = [header_row.length, *body_rows.map(&:length)].max.to_i
          normalized_header = header_row + Array.new([0, column_count - header_row.length].max, "")
          normalized_body = body_rows.map { |row| row + Array.new([0, column_count - row.length].max, "") }
          natural_widths = clacky_table_natural_widths(normalized_header, normalized_body)
          column_widths = clacky_constrain_table_widths(natural_widths)

          headers = normalized_header.each_with_index.map { |cell, index| clacky_wrap_table_cell(clacky_table_cell_text(cell), column_widths[index]) }
          rows = normalized_body.map do |row|
            row.each_with_index.map { |cell, index| clacky_wrap_table_cell(clacky_table_cell_text(cell), column_widths[index]) }
          end

          [headers, rows]
        end

        def clacky_table_natural_widths(header_row, body_rows)
          rows = [header_row] + body_rows
          rows.transpose.map do |cells|
            cells.map { |cell| clacky_visible_width(clacky_table_cell_text(cell)) }.max.to_i
          end
        end

        def clacky_table_cell_text(cell)
          process_inline(cell).to_s.gsub(/\e\[[0-9;:]*m/, "")
        end

        def clacky_constrain_table_widths(natural_widths)
          return natural_widths if natural_widths.empty?

          border_overhead = (natural_widths.length * 3) + 1
          max_table_width = [[@options[:width].to_i - 1, 20].max, border_overhead + natural_widths.length].max
          available_content_width = [max_table_width - border_overhead, natural_widths.length].max
          widths = natural_widths.map { |width| [width, 1].max }
          return widths if widths.sum <= available_content_width

          min_width = available_content_width < natural_widths.length * 3 ? 1 : 3
          while widths.sum > available_content_width
            index = widths.each_with_index.select { |width, _| width > min_width }.max_by(&:first)&.last
            break unless index

            widths[index] -= 1
          end
          widths
        end

        def clacky_wrap_table_cell(text, width)
          width = [width.to_i, 1].max
          text.to_s.split("\n", -1).flat_map do |line|
            clacky_wrap_table_line(line, width)
          end.join("\n")
        end

        def clacky_wrap_table_line(line, width)
          return [""] if line.empty?

          lines = []
          current = +""
          current_width = 0
          in_escape = false
          escape = +""

          line.each_char do |char|
            if in_escape
              escape << char
              if char == "m"
                current << escape
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
            if current_width.positive? && current_width + char_width > width
              lines << current
              current = +""
              current_width = 0
            end
            current << char
            current_width += char_width
          end

          lines << current unless current.empty?
          lines.empty? ? [""] : lines
        end

        def clacky_visible_width(text)
          text.to_s.gsub(/\e\[[0-9;:]*m/, "").split("\n").map(&:display_width).max.to_i
        end
      end
    end
  end

end
