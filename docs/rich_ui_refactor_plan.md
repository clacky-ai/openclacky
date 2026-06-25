# RichUI Controller Refactoring Plan

> Goal: Learn from UI2's MVC layering, componentization, and id-based content management to refactor `lib/clacky/rich_ui_controller.rb` (2336 lines, 12+ classes) into a clear, single-responsibility, maintainable modular architecture.

---

## I. Current State Diagnosis

### 1.1 Core Problems

| Problem | Current State | Impact |
|---------|---------------|--------|
| **Single file too large** | 2336 lines, 12+ classes (Shell, Sidebar, 3 Panels, StatusView, ThinkingLiveView, UIController, 3 Dialogs, 2 Adapters) | High code conflict rate, difficult code review, steep onboarding cost |
| **No MVC layering** | Rendering logic, layout coordinates, business state, and event callbacks all mixed together | Cannot unit-test rendering logic; changing one part may ripple through everything |
| **No component system** | All output is inline string concatenation (`"#{AnsiCode.color(:green)}✓#{reset}"`) | Style leakage, hard to maintain uniformly, not reusable |
| **Centralized monkey patches** | Patches for `RubyRich::Viewport`, `RubyRich::Transcript`, `RubyRich::Markdown::TerminalRenderer` crammed at the top of the file | Patches entangled with business code; concentrated risk when upgrading the gem |
| **Deep coupling with gem internals** | Extensive `instance_variable_get(:@callbacks)`, `instance_variable_set(:@on_interrupt, nil)` | RubyRich internal refactoring causes breakage — fragile external dependency |
| **Dialogs embedded inline** | `ConfigMenuDialog`, `FormDialog`, `ApprovalDialog` defined in the same file | Dialog logic growth further bloats file size |
| **No id-based content management** | Relies on `ruby_rich`'s `transcript.store.entries`; no custom OutputBuffer | Cannot precisely `replace`/`remove` non-tail content; lacks commit dedup mechanism |
| **Theme hardcoded** | `RubyRich::Theme.whale_dark` hardwired in `RichUIController#initialize` | Users cannot switch themes; not interoperable with UI2's theme system |
| **Progress is an adapter wrapper** | `ProgressHandleAdapter` just wraps ruby_rich native handles; no UI2 v2 semantics (owned handle, stack, quiet_on_fast_finish) | Concurrent progress contention; fast-finish unsupported |

### 1.2 Key Gaps vs. UI2

```
UI2 Architecture (mature)                RichUI Architecture (to be refactored)
─────────────────────────────────        ─────────────────────────────────
UIController  (coordination, thin)        RichUIController (coordination + rendering + layout, thick)
  ├── ViewRenderer  (view dispatch)       └── no counterpart, directly manipulates strings
  │     ├── MessageComponent              └── no component, inline concatenation
  │     ├── ToolComponent                 └── no component, inline concatenation
  │     └── CommonComponent               └── no component, inline concatenation
  ├── LayoutManager  (layout engine)      └── no counterpart, relies on RubyRich::Layout
  │     └── OutputBuffer  (id-based)      └── no counterpart, relies on transcript.entries
  ├── ScreenBuffer   (ANSI primitives)    └── no counterpart, encapsulated by ruby_rich
  ├── InputArea      (input editor)       └── RubyRich::Composer (external, but intruded via ivar)
  └── ThemeManager   (theme system)       └── hardcoded Theme.whale_dark
```

---

## II. Refactoring Goals

1. **File splitting**: Single file → multi-file modular, each class in its own file
2. **MVC layering**: Introduce `ViewRenderer` + `Components` + `LayoutAdapter` layers
3. **Componentization**: Extract Panel, Dialog, Status as independent Components
4. **Decouple from gem**: Move monkey patches into `extensions/`; reduce `instance_variable_get`
5. **id-based content management** (optional enhancement): Wrap a lightweight id tracking layer on top of RubyRich Transcript
6. **Theme interoperability**: Reuse or bridge UI2's `ThemeManager` so `--theme` takes effect

---

## III. Target Directory Structure

```
lib/clacky/
├── rich_ui.rb                              # Entry file (similar to ui2.rb)
├── rich_ui/
│   ├── rich_ui_controller.rb               # Thin Controller (from 2336 lines → target < 300 lines)
│   ├── layout_adapter.rb                   # Layout coordination (replaces original LayoutAdapter)
│   ├── progress_handle_adapter.rb          # Progress adapter (existing, retained)
│   │
│   ├── components/                         # View components (similar to ui2/components/)
│   │   ├── base_component.rb               # Base class: provides muted, colored, truncate, etc.
│   │   ├── message_component.rb            # Message rendering (user/assistant/system)
│   │   ├── tool_component.rb               # Tool call/result/error rendering
│   │   ├── common_component.rb             # Progress/success/error/warning rendering
│   │   ├── welcome_banner.rb               # Welcome banner (reuse UI2 or independent impl)
│   │   ├── thinking_live_view.rb           # Thinking area (original ThinkingLiveView)
│   │   ├── status_view.rb                  # Bottom status bar (original RichStatusView)
│   │   ├── sidebar.rb                      # Sidebar container (original RichSidebar)
│   │   ├── sidebar_panels.rb               # WorkPanel/TasksPanel/ContextPanel
│   │   └── dialogs/                        # Dialog components
│   │       ├── base_dialog.rb              # Shared wait/finish/key protocol
│   │       ├── config_menu_dialog.rb       # Model configuration menu
│   │       ├── form_dialog.rb              # Form input
│   │       └── approval_dialog.rb          # Approval confirmation
│   │
│   ├── extensions/                         # Extensions to ruby_rich (replaces top-level monkey patches)
│   │   ├── viewport_selection.rb           # Viewport text selection and clipboard
│   │   ├── transcript_plain.rb             # Transcript plain mode
│   │   └── markdown_table_adapter.rb       # TerminalRenderer table adapter
│   │
│   └── shell/                              # RichAgentShell and its configuration
│       └── rich_agent_shell.rb             # Inherits RubyRich::AgentShell
│
└── cli.rb                                  # Update require paths
```

---

## IV. Phased Implementation Plan

### Phase 1: File Splitting and Directory Setup (Low Risk, Pure Movement)

**Goal**: Split the 2336-line single file into multiple files by class, with zero behavioral change.

| Step | Action |
|------|--------|
| 1.1 | Create `lib/clacky/rich_ui/` directory and subdirectories |
| 1.2 | Move `RichAgentShell` into `rich_ui/shell/rich_agent_shell.rb` |
| 1.3 | Move `RichSidebar` + 3 Panels into `rich_ui/components/sidebar.rb` and `sidebar_panels.rb` |
| 1.4 | Move `ThinkingLiveView` into `rich_ui/components/thinking_live_view.rb` |
| 1.5 | Move `RichStatusView` into `rich_ui/components/status_view.rb` |
| 1.6 | Move 3 Dialogs into `rich_ui/components/dialogs/*.rb`, extract `BaseDialog` |
| 1.7 | Move `LayoutAdapter`, `ProgressHandleAdapter` into `rich_ui/` root directory |
| 1.8 | Create `lib/clacky/rich_ui.rb` entry file, unify requires |
| 1.9 | Update `cli.rb`: `require_relative "rich_ui_controller"` → `require_relative "rich_ui"` |

**Verification**: Run `--ui=rich`; all functionality identical.

---

### Phase 2: Monkey Patch Extraction and Decoupling (Medium Risk)

**Goal**: Convert file-top monkey patches into explicit extension modules, reducing coupling.

#### 2.1 Viewport Selection Extension

**Current state**:
```ruby
class RubyRich::Viewport
  alias_method :clacky_handle_event_without_text_selection, :handle_event
  def handle_event(event_data, layout = nil)
    # ... 30+ lines ...
  end
end
```

**After refactoring**: `lib/clacky/rich_ui/extensions/viewport_selection.rb`
```ruby
module Clacky::RichUI::Extensions::ViewportSelection
  def self.apply!
    RubyRich::Viewport.class_eval do
      # patch here
    end
  end
end

# Explicitly invoked in rich_ui.rb entry point:
Clacky::RichUI::Extensions::ViewportSelection.apply!
```

Benefits:
- Patch code physically isolated from business logic
- `apply!` is explicit — when upgrading the gem you can see at a glance where conflicts might arise
- Can add `apply?` check (`method_defined?`) to avoid double loading

#### 2.2 Markdown Table Extension

Similarly moved into `extensions/markdown_table_adapter.rb`, with explicit `apply!`.

#### 2.3 Reducing `instance_variable_get`

**Current state** (multiple locations):
```ruby
clacky = @shell.instance_variable_get(:@clacky_controller)
status = clacky.instance_variable_get(:@status)
```

**After refactoring**: Provide formal accessors in `RichAgentShell`:
```ruby
class RichAgentShell < RubyRich::AgentShell
  attr_accessor :clacky_controller, :status, :work_label
  # ...
end
```

`RichStatusView` updated to:
```ruby
def render
  clacky = @shell.clacky_controller
  return [""] unless clacky
  status = clacky.status
  # ...
end
```

---

### Phase 3: Introduce ViewRenderer Component Layer (Medium Risk)

**Goal**: Following UI2's `ViewRenderer` + `Components` pattern, extract string concatenation logic into testable components.

#### 3.1 Create BaseComponent

```ruby
# lib/clacky/rich_ui/components/base_component.rb
module Clacky::RichUI::Components
  class BaseComponent
    def muted(text)
      "#{RubyRich::AnsiCode.color(:black, true)}#{text}#{RubyRich::AnsiCode.reset}"
    end

    def colored(text, color)
      "#{RubyRich::AnsiCode.color(color, true)}#{text}#{RubyRich::AnsiCode.reset}"
    end

    def truncate(text, limit = 40)
      # ...
    end
  end
end
```

#### 3.2 Extract Sidebar Panels as Components

Original `RichWorkPanel#render` inline concatenation:
```ruby
def render
  lines = []
  lines << @plan unless @plan.empty?
  # ...
  lines.join("\n")
end
```

After refactoring:
```ruby
class SidebarWorkPanel < BaseComponent
  def render(plan:, activities:, tasks:, cost:)
    lines = []
    lines << plan if plan && !plan.empty?
    # ...
    lines << muted("#{tasks} tasks · $#{cost.round(4)}")
    lines.join("\n")
  end
end
```

Panel classes only retain **state storage**; rendering is delegated to Components.

#### 3.3 Extract Dialog Rendering as Components

`ApprovalDialog`'s `render_content`, `render_choices`, `category_badge`, `colored`, `muted` all use `BaseComponent` methods.

After refactoring structure:
```ruby
class ApprovalDialog
  # Retain: event loop, wait/finish, key binding (these are interaction logic)
  # Remove: string concatenation in render_content → delegate to ApprovalDialogRenderer
end

class ApprovalDialogRenderer < BaseComponent
  def render(tool_name:, message:, params:, risk:, category:, selected_index:)
    # Pure rendering logic, no side effects, unit-testable
  end
end
```

---

### Phase 4: Controller Slimming and Theme Interoperability (Medium Risk)

#### 4.1 Controller Retains Only Coordination Logic

Goal:
```ruby
class RichUIController
  include Clacky::UIInterface

  def initialize(config = {})
    @config = config
    @shell = RichAgentShell.new(...)
    @renderer = ViewRenderer.new        # ← New
    @sidebar = @shell.sidebar            # ← Provided by Shell
    @progress_stack = []                 # ← Prepare for future v2
    wire_callbacks
  end

  def show_tool_call(name, args)
    output = @renderer.render_tool_call(name: name, args: args)
    # ... delegate to ruby_rich for display
  end
end
```

#### 4.2 Reuse UI2 ThemeManager (Optional)

**Approach A (bridge)**: RichUI continues using `RubyRich::Theme`, but maps names like `whale_dark` to UI2 theme names.

**Approach B (unified)**: RichUI components accept UI2's `ThemeManager.current_theme`, calling `theme.format_symbol(:user)` instead of directly using `RubyRich::AnsiCode`.

Recommend **Approach A** (low intrusion), providing theme bridging in `BaseComponent`:
```ruby
def theme
  @theme ||= RubyRich::Theme.whale_dark
end
```

---

### Phase 5: id-based Content Management (Optional Enhancement, High Risk)

UI2's `OutputBuffer` is the essence of its architecture, but RichUI relies on `ruby_rich`'s `Transcript` + `Viewport`; forcibly replacing them is costly.

**Recommended approach**: Introduce a lightweight **EntryTracker** in RichUI instead of a full OutputBuffer.

```ruby
# lib/clacky/rich_ui/entry_tracker.rb
class EntryTracker
  # Tracks message_id / block_id returned by ruby_rich
  # Provides:
  # - register(id, type:) → record id
  # - update(id, content) → call @shell.append_to_message(id, content)
  # - remove(id) → call @shell.transcript.remove_entry(id)
  # - current_tool_id → top-of-stack tool_call id
end
```

Thus `show_tool_call` / `show_tool_result` no longer rely on `@tool_ids.pop` (fragile stack semantics), but instead explicitly track by id.

---

## V. Key Design Decisions

### Decision 1: Should Monkey Patches Be Retained?

**Conclusion**: Retain functionality, but move into `extensions/` directory with explicit `apply!`.

Rationale:
- The RubyRich gem does not provide extension points; without patching, selection/copy cannot be implemented
- Centralized management means only `extensions/` needs checking when upgrading the gem

### Decision 2: Should Dialogs Use RubyRich Native Dialog?

**Conclusion**: Continue using custom Dialogs (`ConfigMenuDialog` etc.), but extract rendering layer into Components.

Rationale:
- RubyRich native Dialog capabilities are limited; current custom Dialogs already implement blocking wait and custom key bindings
- Extracting Renderer decouples Dialog interaction logic from rendering styles

### Decision 3: Should Sidebar Panels Be Split into Separate Files?

**Conclusion**: 3 Panels (Work/Tasks/Context) merged into `sidebar_panels.rb`, but each as an independent class.

Rationale:
- Each Panel is only ~50 lines; separate files would be overly granular
- Merged while maintaining class-level independence, facilitating later Component extraction

### Decision 4: Should ProgressHandle v2 Be Introduced?

**Conclusion**: Keep `ProgressHandleAdapter` bridging for now, but reserve interfaces for the future.

Rationale:
- ruby_rich's `start_progress` / `update` / `finish` semantics differ from UI2; forcing alignment has a wide blast radius
- Can reserve `@progress_stack` in `RichUIController` and implement true stack semantics later

---

## VI. Verification Checklist

After refactoring, the following functionality must be preserved 1:1:

- [ ] `--ui=rich` starts normally, displays welcome banner
- [ ] Full flow: user input → Agent response
- [ ] Tool call cards (start/complete/error)
- [ ] Thinking area real-time streaming
- [ ] Right sidebar (Work/Tasks/Context panels and F1-F4 switching)
- [ ] Bottom status bar (spinner, mode, model, task count, cost)
- [ ] Mouse selection + right-click copy
- [ ] Markdown table adaptive width
- [ ] `/config` dialog (menu + form)
- [ ] Tool approval dialog (ApprovalDialog)
- [ ] Model switch dialog
- [ ] Ctrl+C interrupt, Esc cancel stack, Tab switch mode
- [ ] `--theme` parameter takes effect (or at least does not error)

---

## VII. Estimated Effort

| Phase | Effort | Risk |
|-------|--------|------|
| Phase 1: File splitting | 2-3 hours | Low (pure movement + requires) |
| Phase 2: Patch extraction + decoupling | 3-4 hours | Medium (carefully verify ivar replacements) |
| Phase 3: ViewRenderer + Components | 4-6 hours | Medium (rendering logic extraction, compare output line by line) |
| Phase 4: Controller slimming + themes | 2-3 hours | Medium |
| Phase 5: EntryTracker (optional) | 4-6 hours | High (involves ruby_rich internal id mechanisms) |
| **Total (excluding Phase 5)** | **11-16 hours** | |

---

## VIII. Immediate First Step

If starting the refactoring now, recommended order:

1. **Create directory structure**: `mkdir -p lib/clacky/rich_ui/{components/dialogs,extensions,shell}`
2. **Phase 1 file splitting**: Cut classes one by one into new files, keep original file as compatibility shim (`require_relative "rich_ui"`)
3. **Run smoke test**: `bundle exec ruby ./bin/openclacky agent --ui=rich`, confirm no require errors
4. **Gradual replacement**: Verify after each class move; don't let changes pile up

---

*Plan date: 2026-06-11*
*Reference baseline: UI2 architecture (`lib/clacky/ui2/` directory, docs/ui2-architecture.md)*
