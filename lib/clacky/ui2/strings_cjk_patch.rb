# frozen_string_literal: true

require "strings"

# strings 0.2.1 (latest release, 2021) tracks ANSI reinsertion offsets in
# display width (CJK chars count as 2) but applies them as String character
# indexes via String#insert, so any colored CJK content that needs wrapping
# raises IndexError. These methods mirror upstream with offsets tracked in
# character count instead of display width.
module Strings
  module Wrap
    module_function

    def format_line(text_line, wrap_at, ansi_stack)
      lines = []
      line  = []
      word  = []
      ansi  = []
      ansi_matched = false
      word_length = 0
      line_length = 0
      word_chars = 0
      line_chars = 0
      char_length = 0
      text_length = display_width(text_line)
      total_length = 0

      UnicodeUtils.each_grapheme(text_line) do |char|
        if char == Strings::ANSI::CSI || ansi.length > 0
          ansi << char
          if Strings::ANSI.only_ansi?(ansi.join)
            ansi_matched = true
          elsif ansi_matched
            ansi_stack << [ansi[0...-1].join, line_chars + word_chars]
            ansi_matched = false

            if ansi.last == Strings::ANSI::CSI
              ansi = [ansi.last]
            else
              ansi = []
            end
          end
          next if ansi.length > 0
        end

        char_length = display_width(char)
        total_length += char_length
        if line_length + word_length + char_length <= wrap_at
          if char == SPACE || total_length == text_length
            line << word.join + char
            line_length += word_length + char_length
            line_chars += word_chars + char.size
            word = []
            word_length = 0
            word_chars = 0
          else
            word << char
            word_length += char_length
            word_chars += char.size
          end
          next
        end

        if char == SPACE
          lines << insert_ansi(line.join, ansi_stack)
          line = []
          line_length = 0
          line_chars = 0
          word << char
          word_length += char_length
          word_chars += char.size
        elsif word_length + char_length <= wrap_at
          lines << insert_ansi(line.join, ansi_stack)
          line = [word.join + char]
          line_length = word_length + char_length
          line_chars = word_chars + char.size
          word = []
          word_length = 0
          word_chars = 0
        else # hyphenate word - too long to fit a line
          lines << insert_ansi(word.join, ansi_stack)
          line_length = 0
          line_chars = 0
          word = [char]
          word_length = char_length
          word_chars = char.size
        end
      end
      lines << insert_ansi(line.join, ansi_stack) unless line.empty?
      lines << insert_ansi(word.join, ansi_stack) unless word.empty?
      lines
    end

    def insert_ansi(string, ansi_stack = [])
      return string if ansi_stack.empty?
      return string if string.empty?

      new_stack = []
      output          = string.dup
      length          = string.size
      matched_reset   = false
      ansi_reset      = Strings::ANSI::RESET

      ansi_stack.reverse_each do |ansi|
        pos = ansi[1]
        # Offsets carried over from a previous (longer) line can exceed this
        # line; such codes belong before the wrapped content.
        pos = 0 if pos > length
        if ansi[0] =~ /#{Regexp.quote(ansi_reset)}/
          matched_reset = true
          output.insert(pos, ansi_reset)
          next
        elsif !matched_reset # ansi without reset
          matched_reset = false
          new_stack << ansi # keep the ansi
          next if pos == length
          if output.end_with?(NEWLINE)
            output.insert(-2, ansi_reset)
          else
            output.insert(-1, ansi_reset)
          end
        end

        output.insert(pos, ansi[0])
      end

      ansi_stack.replace(new_stack)

      output
    end
  end
end
