# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.0] - 2026-02-06

This is a major release with significant improvements to skill system, conversation memory management, and user experience.

### 🎯 Major Features

**Skill System**
- Complete skill framework allowing users to extend AI capabilities with custom workflows
- Skills can be invoked using shorthand syntax (e.g., `/commit`, `/gem-release`)
- Support for user-created skills in `.clacky/skills/` directory
- Built-in skills: commit (smart Git helper), gem-release (automated publishing)

**Memory Compression**
- Intelligent message compression to handle long conversations efficiently
- LLM-based compression strategy that preserves context while reducing tokens
- Automatic compression triggered based on message count and token usage
- Significant reduction in API costs for extended sessions

**Configuration Improvements**
- API key validation on startup with helpful prompts
- Interactive configuration UI with modal components
- Source tracking for configuration (file, environment, defaults)
- Better error messages and user guidance

### Added
- Request user feedback tool for interactive prompts during execution
- Version display in welcome banner
- File size limits for file_reader tool to prevent performance issues
- Debug logging throughout the codebase

### Improved
- CLI output formatting and readability
- Error handling with comprehensive debug information
- Test coverage with 367 passing tests
- Tool call output optimization for cleaner logs

### Changed
- Simplified CLI architecture by removing unused code
- Enhanced modal component with new configuration features

### Fixed
- Message compression edge cases
- Various test spec improvements

## [0.6.4] - 2026-02-03

### Added
- Anthropic API support with full Claude model integration
- ClaudeCode environment compatibility (ANTHROPIC_API_KEY support)
- Model configuration with Anthropic defaults (claude-3-5-sonnet-20241022)
- Enhanced error handling with AgentError and ToolCallError classes
- format_tool_results for tool result formatting in agent execution
- Comprehensive test suite for Anthropic API and configuration
- Absolute path handling in glob tool

### Improved
- API client architecture for multi-provider support (OpenAI + Anthropic)
- Config loading with source tracking (file, ClaudeCode, default)
- Agent execution loop with improved tool result handling
- Edit tool with improved pattern matching
- User tip display in terminal

### Changed
- Refactored Error class to AgentError base class
- Renamed connection methods for clarity (connection → openai_connection)

### Fixed
- Handle absolute paths correctly in glob tool

## [0.6.3] - 2026-02-01

### Added
- Complete skill system with loader and core functionality
- Default skill support with auto-loading mechanism
- Skills CLI command for skill management (`clacky skills list/show/create`)
- Command suggestions UI component for better user guidance
- Skip safety check option for safe_shell tool
- UI2 component comprehensive test suite
- Token output control for file_reader and shell tools
- Grep max files limit configuration
- File_reader tool index support
- Web fetch content length limiting

### Improved
- File_reader line range handling logic
- Message compression strategy (100 message compress)
- Inline input wrap line handling
- Cursor position calculation for multi-line inline input
- Theme adjustments for better visual experience
- Skill system integration with agent
- Gem-release skill metadata standardization
- Skill documentation with user experience summaries

### Fixed
- Skill commands now properly pass through to agent
- Session restore data loading with -a or -c flags
- Inline input cursor positioning for wrapped lines
- Multi-line inline input cursor calculation

## [0.6.2] - 2026-01-30

### Added
- `--theme` CLI option to switch UI themes (hacker, minimal)
- Support for reading binary files (with 5MB limit)
- Cost color coding for better visibility
- Install script for easier installation
- New command handling improvements

### Improved
- User input style enhancements
- Tool execution output simplification
- Thinking mode output improvements
- Diff format display with cleaner line numbers
- Terminal resize handling

### Fixed
- BadQuotedString parsing error
- Token counting for every new task
- Shell output max characters limit
- Inline input cursor positioning
- Compress message display (now hidden)

### Removed
- Redundant output components for cleaner architecture

## [0.6.1] - 2026-01-29

### Added
- User tips for better guidance and feedback
- Batch TODO operations for improved task management
- Markdown output support for better formatted responses
- Text style customization options

### Improved
- Tool execution with slow progress indicators for long-running operations
- Progress UI refinements for better visual feedback
- Session restore now shows recent messages for context
- TODO area UI enhancements with auto-hide when all tasks completed
- Work status bar styling improvements
- Text wrapping when moving input to output area
- Safe shell output improvements for better readability
- Task info display optimization (only show essential information)
- TODO list cleanup and organization

### Fixed
- Double paste bug causing duplicate input
- Double error message display issue
- TODO clear functionality
- RSpec test hanging issues

### Removed
- Tool emoji from output for cleaner display

## [0.6.0] - 2026-01-28

### Added
- **New UI System (UI2)**: Complete component-based UI rewrite with modular architecture (InputArea, OutputArea, TodoArea, ToolComponent, ScreenBuffer, LayoutManager)
- **Slash Commands**: `/help`, `/clear`, `/exit` for quick actions
- **Prompt Caching**: Significantly improved performance and reduced API costs
- **Theme System**: Support for multiple UI themes (base, hacker, minimal)
- **Session Management**: Auto-keep last 10 sessions with datetime naming

### Improved
- Advanced inline input with Unicode support, multi-line handling, smooth scrolling, and rapid paste detection
- Better terminal resize handling and flicker-free rendering
- Work/idle status indicators with token cost display
- Enhanced tool execution feedback and multiple tool rejection handling
- Tool improvements: glob limits, grep performance, safe shell security, UTF-8 encoding fixes

### Fixed
- Input flickering, output scrolling, Ctrl+C behavior, image copying, base64 warnings, prompt cache issues

### Removed
- Legacy UI components (Banner, EnhancedPrompt, Formatter, StatusBar)
- Max cost/iteration limits for better flexibility

## [0.5.6] - 2026-01-18

### Added
- **Image Support**: Added support for image handling with cost tracking and display
- **Enhanced Input Controls**: Added Emacs-like Ctrl+A/E navigation for input fields
- **Session Management**: Added `/clear` command to clear session history
- **Edit Mode Switching**: New feature to switch between different edit modes
- **File Operations**: Support for reading from home directory (`~/`) and current directory (`.`)
- **Image Management**: Ctrl+D hotkey to delete images functionality

### Improved
- **Cost Tracking**: Display detailed cost information at every turn for better transparency
- **Performance**: Test suite speed optimizations and performance improvements
- **Token Efficiency**: Reduced token usage in grep operations for cost savings

### Fixed
- Fixed system Cmd+V copy functionality for multi-line text
- Fixed input flickering issues during text editing
- Removed unnecessary blank lines from image handling

## [0.5.4] - 2026-01-16

### Added
- **Automatic Paste Detection**: Rapid input detection automatically identifies paste operations
- **Word Wrap Display**: Long input lines automatically wrap with scroll indicators (up to 15 visible lines)
- **Full-width Terminal Display**: Enhanced prompt box uses full terminal width for better visibility

### Improved
- **Smart Ctrl+C Handling**: First press clears content, second press (within 2s) exits
- **UTF-8 Encoding**: Better handling of multi-byte characters in clipboard operations
- **Cursor Positioning**: Improved cursor tracking in wrapped lines
- **Multi-line Paste**: Better display for pasted content with placeholder support

## [0.5.0] - 2026-01-11

### Added
- **Agent Mode**: Autonomous AI agent with tool execution capabilities
- **Built-in Tools**:
  - `safe_shell` - Safe shell command execution with security checks
  - `file_reader` - Read file contents
  - `write` - Create/overwrite files with diff preview
  - `edit` - Precise file editing with string replacement
  - `glob` - Find files using glob patterns
  - `grep` - Search file contents with regex
  - `web_search` - Search the web for information
  - `web_fetch` - Fetch and parse web pages
  - `todo_manager` - Task planning and tracking
  - `run_project` - Project dev server management
- **Session Management**: Save, resume, and list conversation sessions
- **Permission Modes**:
  - `auto_approve` - Automatically execute all tools
  - `confirm_safes` - Auto-execute safe operations, confirm risky ones
  - `confirm_edits` - Confirm file edits only
  - `confirm_all` - Confirm every tool execution
  - `plan_only` - Plan without executing
- **Cost Control**: Track and limit API usage costs
- **Message Compression**: Automatic conversation history compression
- **Project Rules**: Support for `.clackyrules`, `.cursorrules`, and `CLAUDE.md`
- **Interactive Confirmations**: Preview diffs and shell commands before execution
- **Hook System**: Extensible event hooks for customization

### Changed
- Refactored architecture to support autonomous agent capabilities
- Enhanced CLI with agent command and session management
- Improved error handling and retry logic for network failures
- Better progress indicators during API calls and compression

### Fixed
- API compatibility issues with different providers
- Session restoration with error recovery
- Tool execution feedback loop
- Safe shell command validation
- Edit tool string matching and preview

## [0.1.0] - 2025-12-27

### Added
- Initial release of Clacky
- Interactive chat mode for conversations with Claude
- Single message mode for quick queries
- Configuration management for API keys
- Support for Claude 3.5 Sonnet model
- Colorful terminal output with TTY components
- Secure API key storage in `~/.clacky/config.yml`
- Multi-turn conversation support with context preservation
- Command-line interface powered by Thor
- Comprehensive test suite with RSpec

### Features
- `clacky chat [MESSAGE]` - Start interactive chat or send single message
- `clacky config set` - Configure API key
- `clacky config show` - Display current configuration
- `clacky version` - Show version information
- Model selection via `--model` option

[Unreleased]: https://github.com/yafeilee/clacky/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/yafeilee/clacky/compare/v0.1.0...v0.5.0
[0.1.0]: https://github.com/yafeilee/clacky/releases/tag/v0.1.0
