# OpenClacky Rich UI Mode — Operations and Interface Display

> Source directory: `lib/clacky/rich_ui/`
> Terminal TUI interface built on the RubyRich library

---

## I. Overall Architecture

`lib/clacky/rich_ui` is OpenClacky's terminal TUI interface module, built on the `RubyRich` library, implementing a complete terminal user interaction interface. The core entry point is `RichUIController` (`rich_ui_controller.rb`), which manages layout, components, events, and lifecycle through `RichAgentShell`.

---

## II. Interface Layout (7-layer Zoning)

The interface is defined by the zoning layout in `RichAgentShell#build_layout`:

| Zone | Name | Description |
|------|------|-------------|
| Row 1 | **Header** | Top title bar, displays `OpenClacky` title/subtitle |
| Main body left | **Transcript** | Conversation viewport, displays user messages, assistant replies, tool calls, etc. |
| Main body right | **Sidebar** | Sidebar (36 columns wide), contains Work / Tasks / Context three panels |
| Main body bottom | **ThinkingLive** | Real-time thinking display area (dynamically appears/disappears, height 0 or 6 rows) |
| From row 6 | **Composer** | Input editor, with Framed border titled "Composer" |
| Last row | **Status** | Bottom status bar, displays current mode, model, task count, cost, etc. |

---

## III. Sidebar — Three Information Panels

The sidebar (`RichSidebar`, `components/sidebar.rb`) supports multiple display modes, switched via F1-F4 shortcuts:

- **F1 → Work panel**: Displays plan description, up to 8 recent tool activities (with status markers), task count and cost statistics
- **F2 → Tasks panel**: Displays the current task list (from `update_todos`), with completion progress (e.g. `3/5 done`), status markers:
  - `✓` (green) = Completed
  - `●` (blue) = In progress
  - `!` (red) = Failed
  - `○` (gray) = Pending
- **F3 → Auto mode**: Automatically displays all panels that have content
- **F4 → Context panel**: Displays Token usage details (prompt / output / total / cost)

Sidebar panels are implemented by `components/sidebar_panels.rb`:
- `RichWorkPanel`: Work progress panel
- `RichTasksPanel`: Task list panel
- `RichContextPanel`: Context / Token info panel

---

## IV. Bottom Status Bar

`RichStatusView` (`components/status_view.rb`) renders a single row of status information at the very bottom of the terminal:

- **Idle state**: Shows mode name + "idle" + model name + task count + cost + "Ctrl+C quit"
- **Working**: Shows rotating spinner animation + current tool name (e.g. "web_search…") + model/latency + task count + cost
- **Ctrl+C warning**: Red prompt "Press Ctrl+C again to exit"
- Latency info is appended after the model name (format: `model_name (1.2s)`)

---

## V. Transcript — Operations and Display

### 5.1 Message Display

- **User messages**: Displayed directly in the conversation area
- **Assistant replies**: Rendered in Markdown format (supports code blocks, tables, lists, etc.)
  - Long text (≥240 characters) triggers **streaming rendering**: 6 characters per chunk, 0.03s interval, appearing progressively
  - File summaries are automatically appended at the end of replies (e.g. `Files - path/to/file.rb`)
- **System messages**: Regular info / warning / error displayed in different colors
- **Welcome banner**: On first launch, displays `WelcomeBanner` containing working directory, mode, etc.; if there is session history, shows a "recent session" separator and the last user message

### 5.2 Thinking Process Display (Two Phases)

1. **Live phase**: `ThinkingLiveView` (`components/thinking_live_view.rb`) dynamically appears (occupying 6 rows), renders thinking content character by character in real time, with a rotating spinner and elapsed time counter, stays for about 0.6s after completion
2. **Collapsed phase**: Thinking content is retained in the conversation area as a collapsed block (marked "Xs"), press Ctrl+O to expand and view

### 5.3 Tool Call Display

Each tool call process is visualized in three steps:

- **Start**: Insert a `running` status entry in the conversation area, displaying tool name and parameters (truncated as needed, e.g. `web_search("query...")`, `web_fetch(hostname)`)
- **Complete**: Update entry status to `done` (green `[OK]`), with output content appended
- **Error**: Update entry status to `error` (red `[Error]`), with error message appended

Tool activities are simultaneously synced to the sidebar Work panel (up to 12 entries recorded).

### 5.4 Diff Display

Through the `show_diff` method, using the `Diffy` library to generate unified format diffs, truncated to 50 visible lines (excess lines indicate hidden count), with stats appended (e.g. `+5, -3, 2 hunks`).

### 5.5 Token Usage Display

`show_token_usage` displays prompt/output/total token counts and cost estimates in the conversation area, while syncing to the sidebar Context panel.

### 5.6 Text Selection and Copy

`ViewportSelection` (`extensions/viewport_selection.rb`) extends `RubyRich::Viewport`, supporting:

- **Mouse selection**: Left-click drag to select text, highlighted with reverse color
- **Right-click copy**: Copy selected text to system clipboard
- **Multi-platform clipboard support**: Linux (wl-copy / xclip / xsel), macOS (pbcopy), Windows, with OSC 52 terminal protocol fallback

### 5.7 Table Rendering Optimization

`MarkdownTableAdapter` (`extensions/markdown_table_adapter.rb`) extends RubyRich's Markdown converter, enabling tables to adapt to terminal width: calculating natural column widths, proportionally compressing columns when exceeding terminal width, and auto-wrapping long text.

---

## VI. Composer (Input Area) — Operations

### 6.1 Basic Operations

- **Text input**: Single-line editor, `Shift+Enter` for newline
- **History navigation**: Up/down arrows to browse message history
- **Vim scrolling**: Type `/vim` to toggle, enabling `j`/`k` to scroll the conversation area in single-line mode
- **Clear**: `Ctrl+C` first press interrupts current task, second press exits; `Esc` multi-layer cancel (see below)

### 6.2 Slash Commands

Built-in commands trigger a dropdown menu via `/`:

| Command | Description |
|---------|-------------|
| `/clear` | Clear output and restart session |
| `/config` | Open model configuration dialog |
| `/undo` | Restore previous task state |
| `/help` | Show help information |
| `/exit` | Exit application |
| `/model` | Switch LLM model |

Skill slash commands are also dynamically registered in the Composer menu, with descriptions truncated to 50 characters.

### 6.3 Esc Multi-Layer Cancel Stack

Pressing `Esc` processes in priority order:

1. Close any open dialog (if present)
2. Close slash menu (if open)
3. Interrupt running task
4. Clear input field text (Composer native behavior)

---

## VII. Dialog System

RichUI provides three dialog types, all running in blocking mode (calling `show_blocking_dialog`):

### 7.1 Approval Dialog (ApprovalDialog)

File: `components/dialogs/approval_dialog.rb`

Security confirmation before tool execution, displaying:
- **Tool name** + category badge (File/Shell/Network/Paid, different colors)
- **Risk level**: Low (green), Medium (yellow), High (yellow), Critical (red), with `●○○○` style progress bar
- **Tool info** and parameter details
- Three action buttons: `Approve`, `Deny`, `Always allow` (fingerprint whitelist)

Navigation: `←`/`→` or `h`/`l` to switch options, `Enter` to confirm, `Esc` to deny.

### 7.2 Configuration Menu Dialog (ConfigMenuDialog)

File: `components/dialogs/config_menu_dialog.rb`

Opened by `/config` command, for model management:
- Lists all configured models (showing API Key mask, type labels)
- Actions: Switch model / Add new model / Edit current model / Delete model / Close
- When adding a model, first select Provider (pre-configured vs custom), then fill in API Key, Model name, Base URL form
- Connection test verification available after adding/editing

Navigation: `↑`/`↓` or `j`/`k` to move, `Enter` to select, `q`/`Esc` to cancel.

### 7.3 Form Dialog (FormDialog)

File: `components/dialogs/form_dialog.rb`

General-purpose form input, used for model editing and similar scenarios:
- Supports multiple fields (with labels, default values, placeholders, password masking)
- Focused field shows `➜` marker
- Navigation: `↑`/`↓`/`Tab`/`Shift+Tab` to switch fields, `Enter` to submit, `Esc` to cancel

### 7.4 Model Switch Dialog

Triggered by `/model` command, two-step operation:
1. Select target model from the available model list
2. Choose scope: current session only / save permanently

---

## VIII. Keyboard Shortcut Overview

| Shortcut | Scope | Function |
|----------|-------|----------|
| `Ctrl+C` | Global (within 1s) | Interrupt current task |
| `Ctrl+C` | Global (after 1s) | Exit program |
| `Ctrl+M` | Global (within 2s) | Toggle permission mode (confirm_safes ↔ confirm_all) |
| `Tab` | Global | Toggle permission mode + refocus Composer |
| `F1` | Global | Sidebar → Work panel |
| `F2` | Global | Sidebar → Tasks panel |
| `F3` | Global | Sidebar → Auto mode |
| `F4` | Global | Sidebar → Context panel |
| `Esc` | Global | Multi-layer cancel (dialog→menu→interrupt→clear input) |
| `Shift+Enter` | Composer | Newline |
| `↑`/`↓` | Composer | History message navigation |
| `j`/`k` | Composer (single-line mode) | Scroll conversation area |
| `Ctrl+O` | Transcript | Expand/collapse thinking block |
| Left-click drag | Transcript | Select text |
| Right-click | Transcript | Copy selected text |

---

## IX. Auxiliary Modules

| Module | File | Function |
|--------|------|----------|
| **ViewRenderer** | `view_renderer.rb` | Tool output formatting (`[OK]`/`[Error]`), parameter truncation, tool activity label generation, Diff stat parsing, thinking text extraction, API Key masking, config menu option building, model form validation |
| **EntryTracker** | `entry_tracker.rb` | Lightweight ID tracker, maintains tool call stack (push/pop), ensures correct pairing of tool calls and results |
| **LayoutAdapter** | `layout_adapter.rb` | Layout adapter, provides `clear_output` to clear conversation area |
| **ProgressHandleAdapter** | `progress_handle_adapter.rb` | Wraps RubyRich progress handler, provides `update` / `finish` / `cancel` interface |
| **BaseComponent** | `components/base_component.rb` | Component base class, provides shared rendering methods: `muted`/`colored`/`status_marker`/`truncate`/`theme` |
| **TranscriptPlain** | `extensions/transcript_plain.rb` | Extends Transcript, supports `plain: true` marked plain text entries (for welcome banner, etc.) |
| **MarkdownTableAdapter** | `extensions/markdown_table_adapter.rb` | Monkey patch extending Kramdown-to-RubyRich table conversion, implementing terminal-width-adaptive table wrapping |
| **ViewportSelection** | `extensions/viewport_selection.rb` | Extends viewport, supports text selection and multi-platform clipboard copy |

---

## X. Key Rendering Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `STREAMING_MARKDOWN_THRESHOLD` | 240 chars | Triggers streaming rendering when exceeded |
| `STREAMING_MARKDOWN_CHUNK_SIZE` | 6 chars/chunk | Streaming rendering chunk size |
| `STREAMING_MARKDOWN_DELAY` | 0.03s | Streaming rendering interval |
| Thinking streaming chunk size | 3 chars/chunk | Thinking content streaming display chunk size |
| Thinking streaming delay | 0.008s | Thinking content streaming display interval |
| `SKILL_DESC_MAX` | 50 chars | Skill description truncation length in menu |
| Tool activity record limit | 12 entries | Max entries in sidebar Work panel |
| Diff visible lines | 50 lines | Default max display lines for `show_diff` |
| Tool label truncation | 40 chars | Truncation length for tool call parameter labels |

---

## XI. Source File Listing

```
lib/clacky/rich_ui/
├── rich_ui_controller.rb            # Core controller (824 lines)
├── view_renderer.rb                 # View rendering helper module (291 lines)
├── entry_tracker.rb                 # Entry ID tracker
├── layout_adapter.rb                # Layout adapter
├── progress_handle_adapter.rb       # Progress handler adapter
├── shell/
│   └── rich_agent_shell.rb          # AgentShell in Rich mode
├── components/
│   ├── base_component.rb            # Base component module
│   ├── sidebar.rb                   # Sidebar
│   ├── sidebar_panels.rb            # Sidebar panels (Work/Tasks/Context)
│   ├── status_view.rb               # Status view (bottom status bar)
│   ├── thinking_live_view.rb        # Real-time thinking view
│   └── dialogs/
│       ├── approval_dialog.rb       # Approval dialog
│       ├── form_dialog.rb           # Form dialog
│       └── config_menu_dialog.rb    # Configuration menu dialog
└── extensions/
    ├── markdown_table_adapter.rb    # Markdown table adapter
    ├── transcript_plain.rb          # Plain text transcript extension
    └── viewport_selection.rb        # Viewport text selection extension
```

## XII. Lifecycle

1. `RichUIController#initialize` — Initializes configuration, creates `RichAgentShell`, `LayoutAdapter`, `EntryTracker`, binds callbacks
2. `initialize_and_show_banner` — Sets `running=true`, displays welcome banner or session history
3. `start` → `start_input_loop` → `@shell.start` — Enters terminal event loop
4. User submits input → `on_submit` callback → `@input_callback` → CLI → Agent
5. Agent response → `show_assistant_message` (thinking streaming + Markdown rendering)
6. Tool calls → `show_tool_call` / `show_tool_result` / `show_tool_error`
7. Task complete → `show_complete`, updates status bar and sidebar
8. `stop` — Exits event loop, optional screen clear
