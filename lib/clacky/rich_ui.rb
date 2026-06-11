# frozen_string_literal: true

# RichUI - RubyRich-backed TUI system for Clacky
# Entry point that loads all RichUI modules.

require "ruby_rich"

require_relative "rich_ui/extensions/viewport_selection"
require_relative "rich_ui/extensions/transcript_plain"
require_relative "rich_ui/extensions/markdown_table_adapter"
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

# Apply RubyRich monkey-patches (explicit, review before upgrading gems)
Clacky::RichUI::Extensions::ViewportSelection.apply!
Clacky::RichUI::Extensions::TranscriptPlain.apply!
Clacky::RichUI::Extensions::MarkdownTableAdapter.apply!
