# frozen_string_literal: true

require_relative "clacky/version"
require_relative "clacky/config"
require_relative "clacky/client"
require_relative "clacky/message_compressor"
require_relative "clacky/skill"
require_relative "clacky/skill_loader"

# Agent system
require_relative "clacky/model_pricing"
require_relative "clacky/agent_config"
require_relative "clacky/hook_manager"
require_relative "clacky/tool_registry"
require_relative "clacky/thinking_verbs"
require_relative "clacky/progress_indicator"
require_relative "clacky/session_manager"
require_relative "clacky/gitignore_parser"
require_relative "clacky/utils/limit_stack"
require_relative "clacky/utils/path_helper"
require_relative "clacky/utils/file_ignore_helper"
require_relative "clacky/tools/base"

require_relative "clacky/tools/shell"
require_relative "clacky/tools/file_reader"
require_relative "clacky/tools/write"
require_relative "clacky/tools/edit"
require_relative "clacky/tools/glob"
require_relative "clacky/tools/grep"
require_relative "clacky/tools/web_search"
require_relative "clacky/tools/web_fetch"
require_relative "clacky/tools/todo_manager"
require_relative "clacky/tools/run_project"
require_relative "clacky/tools/safe_shell"
require_relative "clacky/tools/trash_manager"
require_relative "clacky/agent"

require_relative "clacky/cli"

module Clacky
  class AgentError < StandardError; end
  class AgentInterrupted < StandardError; end
  class ToolCallError < AgentError; end  # Raised when tool call fails due to invalid parameters
end
