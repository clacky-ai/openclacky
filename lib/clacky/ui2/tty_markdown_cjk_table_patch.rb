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

      # Each column costs its width plus "| " and " " (three cells) and the
      # closing border. The upstream formula subtracts only n+3, so the table
      # is laid out 2n-2 columns wider than the width it was given.
      private def distribute_widths(widths)
        total_width = widths.reduce(:+)
        screen_width = @width - (widths.size * 3 + 1)
        return widths if total_width <= screen_width

        extra_width = total_width - screen_width
        widths.map do |w|
          ratio = w / total_width.to_f
          [1, w - (extra_width * ratio).floor].max
        end
      end
    end
  end
end

TTY::Markdown::Converter.prepend(Clacky::UI2::TTYMarkdownCJKTablePatch)
