# frozen_string_literal: true

require "ruby_rich"

module Clacky
  module RichUI
    module Extensions
      module MarkdownTableAdapter
        def self.apply!
          RubyRich::Markdown::TerminalConverter.class_eval do
            unless method_defined?(:clacky_fit_table_rows)
              # Override convert_table (Kramdown's entry point for table rendering)
              # to wrap cells to fit the terminal width.
              def convert_table(el)
                header_rows = []
                body_rows = []
                el.children.each do |section|
                  case section.type
                  when :thead
                    section.children.each { |tr| header_rows << collect_row_cells(tr) }
                  when :tbody
                    section.children.each { |tr| body_rows << collect_row_cells(tr) }
                  when :tr
                    body_rows << collect_row_cells(section)
                  end
                end

                return "" if header_rows.empty? || body_rows.empty?

                headers, fitted_body_rows = clacky_fit_table_rows(header_rows.last, body_rows)
                begin
                  tbl = RubyRich::Table.new(
                    headers: headers,
                    border_style: @table_border_style || :simple
                  )
                  fitted_body_rows.each do |row|
                    padded = row + Array.new([0, headers.length - row.length].max, "")
                    tbl.add_row(padded[0...headers.length])
                  end
                  return "#{tbl.render}\n\n"
                rescue
                  # fallback: plain text table
                  result = "\n"
                  result += header_rows.last.join(" | ")
                  result += "\n#{"-" * [result.strip.length, 20].min}\n"
                  body_rows.each { |row| result += row.join(" | ") + "\n" }
                  "#{result}\n"
                end
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
                cell.to_s.gsub(/\e\[[0-9;:]*m/, "")
              end

              def clacky_constrain_table_widths(natural_widths)
                return natural_widths if natural_widths.empty?

                border_overhead = (natural_widths.length * 3) + 1
                max_table_width = [[(@width || 80).to_i - 1, 20].max, border_overhead + natural_widths.length].max
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
    end
  end
end
