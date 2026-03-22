# Clacky UI2 - MVC Terminal UI System

A modern, MVC-based terminal UI system with split-screen layout, component-based rendering, and direct method calls for simplicity.

## Features

- **Split-Screen Layout**: Scrollable output area on top, fixed input area at bottom
- **MVC Architecture**: Clean separation of concerns (Model-View-Controller)
- **Direct Method Calls**: Agent directly calls UIController semantic methods
- **Component-Based**: Reusable, composable UI components
- **Scrollable Output**: Navigate through history with arrow keys
- **Input History**: Navigate previous inputs with up/down arrows
- **Responsive**: Handles terminal resize automatically
- **Rich Formatting**: Colored output with Pastel integration

## Architecture

```
+---------------------------------------------+
|           Business Layer (Agent)            |
|   Agent directly calls @ui.show_xxx()       |
+-----------------------+---------------------+
                        | Direct calls
                        v
+---------------------------------------------+
|        Controller Layer (UIController)      |
|  - show_assistant_message()                 |
|  - show_tool_call()                         |
|  - show_tool_result()                       |
|  - request_confirmation()                   |
+-----------------------+---------------------+
                        | Render
                        v
+---------------------------------------------+
|          View Layer (ViewRenderer)          |
|  - Components (Message, Tool, Status)       |
+---------------------------------------------+
```

## Quick Start

### Agent Integration

```ruby
# Create UI controller
ui_controller = Clacky::UI2::UIController.new(
  working_dir: Dir.pwd,
  mode: "confirm_safes",
  model: "claude-3-5-sonnet"
)

# Create agent with UI injected
agent = Clacky::Agent.new(client, config, ui: ui_controller)

# Set up input handler
ui_controller.on_input do |input, images|
  result = agent.run(input, images: images)
end

# Start UI (blocks until exit)
ui_controller.start
```

### UIController Semantic Methods

The Agent calls these methods directly:

```ruby
# Show messages
@ui.show_assistant_message("Hello!")
@ui.show_user_message("Hi there", files: [])

# Show tool operations
@ui.show_tool_call("file_reader", { path: "test.rb" })
@ui.show_tool_result("File contents...")
@ui.show_tool_error("File not found")

# Show status
@ui.show_progress("Thinking...")
@ui.clear_progress
@ui.show_complete(iterations: 5, cost: 0.001)

# Show info/warning/error
@ui.show_info("Session saved")
@ui.show_warning("Rate limited")
@ui.show_error("Failed to connect")

# Interactive confirmation
result = @ui.request_confirmation("Allow file write?", default: true)
# Returns: true/false for yes/no, String for feedback, nil for cancelled

# Show diff
@ui.show_diff(old_content, new_content, max_lines: 50)
```

## Components

### ViewRenderer

Unified interface for rendering all UI components.

```ruby
renderer = Clacky::UI2::ViewRenderer.new

# Render messages
renderer.render_user_message("Hello")
renderer.render_assistant_message("Hi there")

# Render tools
renderer.render_tool_call(
  tool_name: "file_reader",
  formatted_call: "file_reader(path: 'test.rb')"
)
renderer.render_tool_result(result: "Success")

# Render status
renderer.render_status(
  iteration: 5,
  cost: 0.1234,
  tasks_completed: 3,
  tasks_total: 10
)
```

### OutputArea

Scrollable output buffer with automatic line wrapping.

```ruby
output = Clacky::UI2::Components::OutputArea.new(height: 20)

output.append("Line 1")
output.append("Line 2\nLine 3")

output.scroll_up(5)
output.scroll_down(2)
output.scroll_to_top
output.scroll_to_bottom

output.at_bottom? # => true/false
output.scroll_percentage # => 0.0 to 100.0
```

### InputArea

Fixed input area with cursor support and history.

```ruby
input = Clacky::UI2::Components::InputArea.new(height: 2)

input.insert_char("H")
input.backspace
input.cursor_left
input.cursor_right

value = input.submit # Returns and clears input
input.history_prev   # Navigate history
```

### LayoutManager

Manages screen layout and coordinates rendering.

```ruby
layout = Clacky::UI2::LayoutManager.new(
  output_area: output,
  input_area: input
)

layout.initialize_screen
layout.append_output("Hello")
layout.move_input_to_output
layout.scroll_output_up(5)
layout.cleanup_screen
```

## Keyboard Shortcuts

- **Enter** - Submit input
- **Ctrl+C** - Exit/Interrupt
- **Ctrl+L** - Clear output
- **Ctrl+U** - Clear input line
- **Up/Down** - Scroll output (when input empty) or navigate history
- **Left/Right** - Move cursor in input
- **Home/End** - Jump to start/end of input
- **Backspace** - Delete character before cursor
- **Delete** - Delete character at cursor

## Layout Structure

```
+----------------------------------------+
|         Output Area (Scrollable)       | <- Lines 0 to height-4
|  [<<] Assistant: Hello...              |
|  [=>] Tool: file_reader                |
|  [<=] Result: ...                      |
|  ...                                   |
+----------------------------------------+ <- Separator
| [>>] Input: _                          | <- Input line
+----------------------------------------+ <- Session bar
| Mode: confirm_safes | Tasks: 5 | $0.01 |
+----------------------------------------+
```

## Design Principles

1. **Simplicity**: Agent directly calls UIController methods - no middleware
2. **Dependency Injection**: Agent receives `ui:` parameter
3. **Component-Based**: Reusable, testable UI components
4. **Responsive**: Handles terminal resize and edge cases

## License

MIT
