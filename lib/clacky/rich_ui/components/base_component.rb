# frozen_string_literal: true

require "ruby_rich"

module Clacky
  module RichUI
    module Components
      # BaseComponent provides shared rendering primitives for RichUI components.
      # Used by sidebar panels and dialogs to eliminate duplicated ANSI-color helpers.
      module BaseComponent
        # Render muted (dim) text commonly used for secondary info
        def muted(text)
          "#{RubyRich::AnsiCode.color(:black, true)}#{text}#{RubyRich::AnsiCode.reset}"
        end

        # Render colored text with a named color
        def colored(text, color)
          "#{RubyRich::AnsiCode.color(color, true)}#{text}#{RubyRich::AnsiCode.reset}"
        end

        # Status marker symbol for todo / activity items
        def status_marker(status)
          case status
          when :done, :completed
            colored("✓", :green)
          when :running, :in_progress, :active
            colored("●", :blue)
          when :failed, :error
            colored("!", :red)
          else
            muted("○")
          end
        end

        # Truncate text to a maximum length, appending "…" when cut
        def truncate(text, limit = 40)
          return "" if text.nil? || text.empty?

          text.length > limit ? "#{text[0...limit]}…" : text
        end

        # Theme accessor for future theme switching.
        # Currently defaults to agent_dark; can be overridden per-component.
        def theme
          @theme ||= RubyRich::Theme.agent_dark
        end
      end
    end
  end
end
