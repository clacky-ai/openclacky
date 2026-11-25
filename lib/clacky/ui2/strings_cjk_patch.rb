# frozen_string_literal: true

require "strings"

# strings 0.2.1 (latest release, 2021) re-wraps coloured text by remembering
# where every escape sequence started and inserting it back with
# String#insert. Three things go wrong with that:
#
# - Offsets are tracked in display width (CJK counts as 2) but applied as
#   character indexes, so coloured CJK content raises IndexError.
# - The offset stack is shared across lines, so a position recorded on one
#   line lands inside another line's characters. "\e[38;5;230m" came out as
#   "\e[38;5" plus a literal "230m" printed to the user.
# - The early bail-out compares the printable *character* count with wrap_at.
#   Forty Chinese characters are eighty columns, so such a line is returned
#   unwrapped and overflows the pane.
#
# The wrapper below is token based instead: an escape sequence is a
# zero-width token that is always copied whole, and the colours still open at
# a break are replayed on the continuation line. Output offsets cannot drift
# because nothing is ever inserted at a remembered position.
module Strings
  # Upstream ANSI_MATCHER ends with an optional `([\];])?` group, so a literal
  # ";" right after a color code is swallowed along with it: the text
  # "\e[38;5;230m;230m" is measured as "230m", one column short of what the
  # terminal actually shows, and the table's right border lands one cell left.
  # Strip well-formed CSI sequences first and only fall back to the loose
  # matcher for genuinely broken leftovers.
  module ANSI
    CSI_SEQUENCE = /\e\[[0-9:;<=>?]*[ -\/]*[@-~]/.freeze
    CSI_TOKEN = /\A\e\[[0-9:;<=>?]*[ -\/]*[@-~]\z/.freeze
    module_function

    def sanitize(string)
      cleaned = string.gsub(CSI_SEQUENCE, "")
      return cleaned unless cleaned.include?("\e")

      cleaned.gsub(/#{ANSI_MATCHER}/, "")
    end
    module_function :sanitize
  end

  module Wrap
    # Codes that end whatever colour was open before them.
    RESET_TOKENS = "\e[0m\e[m\e[39m\e[49m"
    # A line with more open colours than this is replayed from the most
    # recent ones only; keeps the prefix bounded on pathological input.
    MAX_ACTIVE = 8

    module_function

    def wrap(text, wrap_at = DEFAULT_WIDTH, separator: NEWLINE)
      width = wrap_at.to_i
      return text if width.zero?
      return text if text.lines.all? { |line| visible_width(line.chomp) <= width }

      text.lines.map { |line| wrap_line(line, width).join(separator) }.join
    end

    # Split one line (which may carry colour) into chunks of at most `width`
    # display columns. Word boundaries are respected; a single word wider
    # than the line – the normal case for Chinese, which has no spaces – is
    # broken between graphemes instead of being emitted oversized.
    def wrap_line(line, width)
      ending = line.end_with?(NEWLINE) ? NEWLINE : ""
      tokens = tokenize(ending.empty? ? line : line.chomp)

      chunks = []
      current = []
      current_width = 0

      words(tokens).each do |word|
        word_width = word.sum { |token| token[1] }

        if current_width + word_width <= width
          current.concat(word)
          current_width += word_width
          next
        end

        unless current.empty?
          chunks << current
          current = []
          current_width = 0
        end

        if word_width <= width
          current = word.dup
          current_width = word_width
          next
        end

        word.each do |token|
          if current_width.positive? && current_width + token[1] > width
            chunks << current
            current = []
            current_width = 0
            next if token[0] == SPACE
          end
          current << token
          current_width += token[1]
        end
      end
      chunks << current unless current.empty?

      render_chunks(chunks, ending)
    end

    # @return [Array<Array(String, Integer)>] graphemes paired with their
    #   display width, plus whole escape sequences paired with 0.
    def tokenize(text)
      tokens = []
      escape = nil

      UnicodeUtils.each_grapheme(text) do |char|
        if escape
          escape << char
          if escape.match?(ANSI::CSI_TOKEN) || escape.size > 16
            tokens << [escape, 0]
            escape = nil
          end
          next
        end

        if char == "\e"
          escape = +"\e"
          next
        end

        tokens << [char, Unicode::DisplayWidth.of(char)]
      end
      tokens << [escape, 0] if escape

      tokens
    end

    # Group tokens into words. A word keeps its trailing space, which is what
    # makes the chunks add up to the original text.
    def words(tokens)
      result = []
      word = []
      tokens.each do |token|
        word << token
        next unless token[0] == SPACE

        result << word
        word = []
      end
      result << word unless word.empty?

      result
    end

    # Turn token chunks into strings, replaying the colour that is still open
    # at the start of each chunk and closing every chunk that leaves one open.
    def render_chunks(chunks, ending)
      active = []
      rendered = chunks.each_with_index.map do |chunk, index|
        text = chunk.map { |token| token[0] }.join
        body = active.empty? ? text : active.join + text
        chunk.each { |token| track(active, token[0]) }
        body += Strings::ANSI::RESET unless active.empty?
        index == chunks.size - 1 ? body + ending : body
      end

      rendered.empty? ? [ending] : rendered
    end

    def track(active, text)
      return unless text.getbyte(0) == 27

      if RESET_TOKENS.include?(text)
        active.clear
      else
        active << text
        active.shift while active.size > MAX_ACTIVE
      end
    end

    def visible_width(text)
      return 0 if text.empty?

      Unicode::DisplayWidth.of(Strings::ANSI.sanitize(text))
    end
  end
end
