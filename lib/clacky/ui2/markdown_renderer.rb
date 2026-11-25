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
      BOX_OPEN = /\A\s*┌.*┐\s*\z/.freeze
      BOX_ROW_END = /[│┐┘┤]\z/.freeze
      BOX_CHARS = "│┌┐└┘├┤┬┴┼"
      BOX_CORNERS = "┌┐└┘"
      # Frame followed by a floating label, e.g. `│ + │  ← tab bar`.
      BOX_ANNOTATED = /\A(.*│)(\s{2,}[^\s│┌┐└┘├┤┬┴┼][^│┌┐└┘├┤┬┴┼]*)\z/.freeze

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

          content = align_box_diagrams(content)

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

        # Models pad box rows by character count, so a CJK row comes out wider
        # than the frame it sits in. Every frame in one diagram is given the
        # same width, and cell separators follow the border row above them.
        def align_box_diagrams(content)
          return content unless content.include?("┌")

          lines = content.lines
          out = []
          index = 0
          while index < lines.size
            if lines[index].chomp.match?(BOX_OPEN)
              stop = index
              stop += 1 while stop + 1 < lines.size && box_block_line?(lines[stop + 1])
              out.concat(align_box_block(lines[index..stop]))
              index = stop + 1
              next
            end
            out << lines[index]
            index += 1
          end
          out.join
        end

        def box_block_line?(line)
          text = line.chomp
          return false if text.strip.empty?

          text.match?(BOX_ROW_END) || text.match?(/\A\s*│/)
        end

        # Frames grow to the widest row instead of cutting content.
        def align_box_block(rows)
          aligned = align_box_cells(rows)
          target = aligned.map { |row| box_width(row.chomp) }.compact.max
          aligned.map do |row|
            ending = row.end_with?("\n") ? "\n" : ""
            body, label = box_split_label(row.chomp)
            # A connector carrying a label is not a frame row; padding it would
            # shove the label past the frame it annotates.
            resized = label && body.count(BOX_CHARS) < 2 ? body : box_resize(body, target)
            resized = "#{resized}  #{label}" if label
            resized + ending
          end
        end

        def box_split_label(text)
          match = text.match(BOX_ANNOTATED)
          return [text, nil] unless match

          [match[1], match[2].strip]
        end

        def box_width(body)
          text, = box_split_label(body.rstrip)
          text.rstrip.match?(BOX_ROW_END) ? Unicode::DisplayWidth.of(text.rstrip) : nil
        end

        def align_box_cells(rows)
          ref = nil
          rows.map do |row|
            text = row.chomp.rstrip
            if box_grid_row?(text) || (text.match?(/[┬┼]/) && text.match?(/[┌├]/))
              ref = box_bar_columns(text, BOX_CHARS)
              row
            elsif text.match?(/\A\s*[└┘]/)
              ref = nil
              row
            elsif text.match?(/\A\s*│/) && text.match?(BOX_ROW_END)
              bars = box_bar_columns(text, "│")
              target = box_target_bars(ref, bars)
              rebuilt = target && box_rebuild_row(text, target)
              ref ||= bars if bars.size > 2
              rebuilt ? rebuilt + (row.end_with?("\n") ? "\n" : "") : row
            else
              row
            end
          end
        end

        # A frame holding free-standing boxes (no ┬/┼ anywhere) is gridded by
        # those boxes' own corners, e.g. `│  ┌──┐  ┌──┐  │`.
        def box_grid_row?(text)
          text.match?(/\A\s*│/) && text.count(BOX_CORNERS) >= 2
        end

        # A border row is the grid; a frame drawn without one falls back to its
        # first content row, so the rest of the frame at least agrees with it.
        def box_target_bars(ref, bars)
          return nil if ref.nil?

          inner = bars[1..-2] || []
          target = ref.size == inner.size ? ref : (ref[1..-2] || [])
          return nil if inner.empty? || target.size != inner.size

          [bars.first] + target + [bars.last]
        end

        # A cell that cannot fit its column leaves the row alone rather than
        # half-aligned; an exact fit closes the gap and keeps the bars lined up.
        def box_rebuild_row(text, target_bars)
          cells = text.split("│", -1)
          return nil if cells.size != target_bars.size + 1

          widths = (0...(target_bars.size - 1)).map do |i|
            target_bars[i + 1] - target_bars[i] - 1
          end
          fitted = (0...widths.size).map { |i| box_fit(cells[i + 1], widths[i]) }
          return nil if fitted.include?(nil)

          out = +cells[0]
          fitted.each { |cell| out << "│" << cell }
          out << "│" << cells[-1]
        end

        def box_bar_columns(text, chars)
          cols = []
          width = 0
          text.each_char do |char|
            cols << width if chars.include?(char)
            width += Unicode::DisplayWidth.of(char)
          end
          cols
        end

        def box_fit(cell, width)
          text = cell.strip
          pad = width - Unicode::DisplayWidth.of(text)
          return nil if pad.negative?
          return text if pad.zero?

          " " + text + " " * (pad - 1)
        end

        def box_resize(body, target)
          text = body.rstrip
          return body unless text.match?(BOX_ROW_END)

          diff = target - Unicode::DisplayWidth.of(text)
          return text if diff <= 0

          filler = text.lstrip.start_with?("┌", "└", "├") ? "─" : " "
          text[0...-1] + filler * diff + text[-1]
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
