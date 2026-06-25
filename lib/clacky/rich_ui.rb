# frozen_string_literal: true

# RichUI - RubyRich-backed TUI system for Clacky
# Entry point that loads all RichUI modules.

require "ruby_rich"

module Clacky
  module RichUI
    module ViewportSelectionPatch
      def highlight_display_range(line, start_col, end_col)
        end_col = [end_col, visible_text_width(line.to_s.rstrip)].min
        return line if end_col <= start_col

        super(line, start_col, end_col)
      end

      private def visible_text_width(line)
        width = 0
        in_escape = false

        line.each_char do |char|
          if in_escape
            in_escape = false if char == "m"
            next
          end

          if char.ord == 27
            in_escape = true
            next
          end

          width += Unicode::DisplayWidth.of(char)
        end

        width
      end
    end
  end
end

RubyRich::Viewport.prepend(Clacky::RichUI::ViewportSelectionPatch)

require_relative "rich_ui/components/base_component"
require_relative "rich_ui/view_renderer"
require_relative "rich_ui/entry_tracker"
require_relative "rich_ui/components/sidebar_panels"
require_relative "rich_ui/components/sidebar"
require_relative "rich_ui/components/thinking_live_view"
require_relative "rich_ui/components/status_view"
require_relative "rich_ui/shell/rich_agent_shell"
require_relative "rich_ui/layout_adapter"
require_relative "rich_ui/progress_handle_adapter"
require_relative "rich_ui/components/dialogs/config_menu_dialog"
require_relative "rich_ui/components/dialogs/form_dialog"
require_relative "rich_ui/components/dialogs/approval_dialog"
require_relative "rich_ui/rich_ui_controller"
