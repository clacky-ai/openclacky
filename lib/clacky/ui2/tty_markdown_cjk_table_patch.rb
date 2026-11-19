# frozen_string_literal: true

require "tty-markdown"
require "unicode/display_width"

# tty-markdown sizes table columns with String#length, i.e. character count.
# A cell holding 40 Chinese characters is reported as 40 columns wide but
# occupies 80, so the table is laid out narrower than its content: text runs
# past the border, the block overflows the terminal, and every line after it
# is pushed around. Measure the display width instead.
module Clacky
  module UI2
    module TTYMarkdownCJKTablePatch
      private def max_width(table_data, col)
        table_data.map do |row|
          Strings.sanitize(row[col].join).lines.map { |line| Unicode::DisplayWidth.of(line) }.max || 0
        end.max
      end

      # Each column costs its width plus one space of padding on either side,
      # plus one border character per column edge, plus the trailing space
      # tty-markdown leaves at the end of every row, plus the indent the block
      # is drawn at: sum(widths) + 3n + 2 + indent. Upstream subtracts only
      # n + 3, so the table comes out wider than the width it was given and
      # its right border is cut off by the pane.
      #
      # Shrinking every column by its proportional share is wrong too, even
      # when the rounding is exact: a 4-column table with natural widths of
      # roughly 8/24/56/90 columns gave the first column 5 cells, so "方面"
      # broke into one character per row. That tripled the table's height,
      # which is what made the screen below it redraw over stale rows.
      # Lower a shared ceiling instead: narrow columns keep what they need,
      # wide columns give up their spare space evenly.
      private def distribute_widths(widths)
        budget = @width - (widths.size * 3 + 2) - @current_indent.to_i
        budget = [budget, widths.size].max
        return widths if widths.sum <= budget

        level = widths.max
        while level > 1 && widths.sum { |w| [w, level].min } > budget
          level -= 1
        end
        cells = widths.map { |w| [w, level].min }

        # The ceiling is a whole number, so a few cells are left over. Hand
        # them back to the columns that were cut the most.
        trimmed = widths.each_index.select { |i| widths[i] > cells[i] }.sort_by { |i| -widths[i] }
        leftover = budget - cells.sum
        if leftover.positive? && !trimmed.empty?
          leftover.times { |i| cells[trimmed[i % trimmed.size]] += 1 }
        end

        cells
      end
    end
  end
end

TTY::Markdown::Converter.prepend(Clacky::UI2::TTYMarkdownCJKTablePatch)
