# frozen_string_literal: true

require "tty-screen"
require_relative "theme_manager"
require_relative "strings_cjk_patch"
# Must come after strings_cjk_patch: the strings gem pins unicode-display_width
# to < 3.0, and loading it first would activate whatever newer version is
# installed globally, which then makes `require "strings"` fail with a
# Gem::ConflictError outside of bundler.
require "unicode/display_width"

module Clacky
  module UI2
    # MarkdownRenderer handles rendering Markdown content with syntax highlighting
    module MarkdownRenderer
      class << self
        # Render markdown content with theme-aware colors
        # @param content [String] Markdown content to render
        # @return [String] Rendered content with ANSI colors
        def render(content)
          return content if content.nil? || content.empty?

          # tty-markdown pulls in rouge + kramdown (~0.4s). Server mode renders
          # markdown in the browser, so only pay that cost on a real terminal render.
          require "tty-markdown" unless defined?(TTY::Markdown)
          # Tables need CJK-aware column widths before anything is rendered.
          require_relative "tty_markdown_cjk_table_patch" unless defined?(Clacky::UI2::TTYMarkdownCJKTablePatch)

          # Get current theme colors
          theme = ThemeManager.current_theme

          width = TTY::Screen.width - 4  # Leave some margin

          # Configure tty-markdown with custom theme and symbols
          parsed = TTY::Markdown.parse(content, 
            theme: theme_colors,
            symbols: custom_symbols,
            width: width
          )

          fit_to_width(parsed, width)
        rescue IndexError => e
          # Safety net behind strings_cjk_patch; retry uncolored if wrap still fails.
          warn "[markdown] color render failed (#{e.class}), retrying without color" if ENV["CLACKY_DEBUG"]
          begin
            TTY::Markdown.parse(content, color: :never, symbols: custom_symbols, width: width)
          rescue StandardError
            content
          end
        rescue StandardError => e
          warn "[markdown] render failed: #{e.class}: #{e.message}" if ENV["CLACKY_DEBUG"]
          content
        end

        # tty-markdown wraps one inline element at a time, so a paragraph that
        # alternates Chinese text with `inline code` is only as short as its
        # longest single element. A 240-column line came out of a 136-column
        # pane: the terminal hard-wrapped it, every following line moved down
        # one row and the whole screen below it shifted (overlapping text,
        # borders in the wrong place).
        #
        # Re-wrap the finished lines, as whole strings, so a line always fits.
        # Continuation lines keep the indent (and the width of a list marker)
        # so lists still line up. Table rows are left alone: wrapping them
        # would break the grid.
        def fit_to_width(rendered, limit)
          return rendered if limit.to_i <= 0

          rendered.lines.flat_map { |line| rewrap_line(line, limit) }.join
        end

        def rewrap_line(line, limit)
          text = line.chomp
          plain = Strings::ANSI.sanitize(text)
          ending = line.end_with?("\n") ? "\n" : ""

          if table_row?(plain)
            return [line] if Unicode::DisplayWidth.of(plain) <= limit

            # tty-markdown pads every row with one trailing space, which can
            # push an otherwise exact table one column past the pane. The
            # space is not part of the grid, so drop it.
            trimmed = trim_trailing_spaces(text)
            if Unicode::DisplayWidth.of(Strings::ANSI.sanitize(trimmed)) <= limit
              return [trimmed + ending]
            end

            return [line]
          end

          return [line] if Unicode::DisplayWidth.of(plain) <= limit

          indent = plain[/\A */].size
          marker = plain[indent..].to_s[/\A(?:●|◆|◇|○|\d{1,3}\.|[-*])\s+/].to_s
          offset = indent + Unicode::DisplayWidth.of(marker)
          available = limit - offset
          return [line] if available < 8

          # tty-markdown colours plain paragraphs too, so almost every long
          # line starts with an escape code. Bailing out on that is what left
          # a 242-column line in a 136-column pane. Split the prefix by display
          # width instead, and keep the opening codes on every continuation.
          prefix, body = split_at_display_width(text, offset)
          return [line] if body.nil? || body.empty?

          wrapped = wrap_colored(body, available, " " * offset)
          return [line] if wrapped.size <= 1

          ([prefix + wrapped.first] + wrapped.drop(1)).map { |part| part + ending }
        end

        # Wrap coloured text without ever cutting an escape sequence.
        #
        # Strings.wrap keeps ANSI reinsertion offsets and inserts them back with
        # String#insert; with several codes on one line the offset lands inside
        # another sequence, so "\e[97m" becomes "\e" + "[97m" and the terminal
        # prints "97m" as text. Treat an escape sequence as a zero-width token
        # instead: it is copied whole, remembered as the active colour, and
        # replayed at the start of every continuation line.
        def wrap_colored(text, width, indent = "")
          lines = []
          current = +""
          current_width = 0
          active = []
          escape = nil

          UnicodeUtils.each_grapheme(text) do |char|
            if escape
              escape << char
              next unless char == "m"

              current << escape
              if escape == Strings::ANSI::RESET
                active.clear
              else
                active << escape
                active.shift while active.size > 8
              end
              escape = nil
              next
            end

            if char == "\e"
              escape = +"\e"
              next
            end

            char_width = Unicode::DisplayWidth.of(char)
            if current_width.positive? && current_width + char_width > width
              lines << current
              current = +(indent + active.join)
              current_width = 0
              next if char == " "
            end

            current << char
            current_width += char_width
          end

          lines << current
          lines
        end

        # Take the leading prefix of `text` whose *display* width is `target`,
        # stepping over escape sequences instead of counting their characters.
        def split_at_display_width(text, target)
          return ["", text] if target <= 0

          width = 0
          index = 0
          while index < text.length && width < target
            if text[index] == "\e"
              match = text[index..].match(/\A\e\[[0-9;]*m/)
              index += match[0].length
              next
            end
            width += Unicode::DisplayWidth.of(text[index])
            index += 1
          end

          [text[0...index], text[index..].to_s]
        end

        def table_row?(plain)
          plain.strip.start_with?("│", "┌", "├", "└", "|")
        end

        # Remove the padding spaces at the end of a line while keeping any
        # escape sequences that follow them.
        def trim_trailing_spaces(text)
          text.sub(/( +)((?:\e\[[0-9;]*m)+)\z/, '\2').sub(/ +\z/, "")
        end

        # Check if content looks like markdown
        # @param content [String] Content to check
        # @return [Boolean] true if content appears to be markdown
        def markdown?(content)
          return false if content.nil? || content.empty?

          # Check for common markdown patterns
          content.match?(/^#+ /) ||           # Headers
            content.match?(/```/) ||          # Code blocks
            content.match?(/^\s*[-*+] /) ||   # Unordered lists
            content.match?(/^\s*\d+\. /) ||   # Ordered lists
            content.match?(/\[.+\]\(.+\)/) || # Links
            content.match?(/^\s*> /) ||       # Blockquotes
            content.match?(/\*\*.+\*\*/) ||   # Bold
            content.match?(/`.+`/) ||         # Inline code
            content.match?(/^\s*\|.+\|/) ||   # Tables
            content.match?(/^---+$/)          # Horizontal rules
        end


        # Get theme-aware colors for markdown rendering
        # @return [Hash] Color configuration for tty-markdown
        def theme_colors
          theme = ThemeManager.current_theme

          # tty-markdown accepts a single :header key for all header levels
          # (h1 additionally underlines). Code block colors come from rouge.
          {
            header: [:bright_cyan, :bold],
            # Horizontal rule - make it subtle (dim gray)
            hr: [:bright_black],
            # Links use success color (green)
            link: Array(theme.colors[:success]),
            # Lists use default text color
            list: [:bright_white],
            # Strong/bold use bright white
            strong: [:bright_white, :bold],
            # Emphasis/italic use white
            em: [:white],
            # Note/blockquote use dim color
            note: Array(theme.colors[:thinking]),
            quote: Array(theme.colors[:thinking]),
          }
        end

        # Get custom symbols for markdown rendering
        # @return [Hash] Symbol configuration for tty-markdown
        def custom_symbols
          {
            override: {
              # Make horizontal rule simpler - just a line without decorative diamonds
              diamond: "",
              line: "-"
            }
          }
        end
      end
    end
  end
end
