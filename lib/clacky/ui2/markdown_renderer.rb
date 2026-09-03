# frozen_string_literal: true

require "tty-screen"
require_relative "theme_manager"
require_relative "strings_cjk_patch"

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

          # Get current theme colors
          theme = ThemeManager.current_theme

          width = TTY::Screen.width - 4  # Leave some margin

          # Configure tty-markdown with custom theme and symbols
          parsed = TTY::Markdown.parse(content, 
            theme: theme_colors,
            symbols: custom_symbols,
            width: width
          )

          parsed
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
