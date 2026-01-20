# Clacky UI2 - MVC Terminal UI System

A modern, MVC-based terminal UI system with split-screen layout, event-driven architecture, and component-based rendering.

## Features

- **Split-Screen Layout**: Scrollable output area on top, fixed input area at bottom
- **MVC Architecture**: Clean separation of concerns (Model-View-Controller)
- **Event-Driven**: Publish-subscribe pattern decouples business logic from UI
- **Component-Based**: Reusable, composable UI components
- **Scrollable Output**: Navigate through history with arrow keys
- **Input History**: Navigate previous inputs with up/down arrows
- **Responsive**: Handles terminal resize automatically
- **Rich Formatting**: Colored output with Pastel integration

## Architecture

```
┌─────────────────────────────────────────┐
│           Business Layer                │
│   (Agent, Tools - data only)            │
└────────────┬────────────────────────────┘
             │ Events
             ▼
┌─────────────────────────────────────────┐
│        Controller Layer                 │
│  - UIController                         │
│  - EventBus                             │
└────────────┬────────────────────────────┘
             │ Render
             ▼
┌─────────────────────────────────────────┐
│          View Layer                     │
│  - ViewRenderer                         │
│  - Components (Message, Tool, Status)   │
└─────────────────────────────────────────┘
```

## Quick Start

### Simple Usage

```ruby
require "clacky/ui2"

# Start with a simple callback
Clacky::UI2.start do |input|
  puts "User said: #{input}"
end
```

### Full Controller

```ruby
require "clacky/ui2"

# Create controller
controller = Clacky::UI2::UIController.new

# Handle user input
controller.on_input do |input|
  # Echo user message
  controller.event_bus.publish(:user_message, {
    content: input,
    timestamp: Time.now
  })
  
  # Simulate response
  controller.event_bus.publish(:assistant_message, {
    content: "I received: #{input}",
    timestamp: Time.now
  })
end

# Start the UI
controller.start
```

### Event-Driven Architecture

```ruby
# Subscribe to events
controller.event_bus.on(:custom_event) do |data|
  controller.append_output("Custom: #{data.inspect}")
end

# Publish events
controller.event_bus.publish(:custom_event, { key: "value" })
```

## Components

### EventBus

Publish-subscribe event system for decoupling components.

```ruby
bus = Clacky::UI2::EventBus.new

# Subscribe
subscription_id = bus.on(:my_event) do |data|
  puts "Received: #{data}"
end

# Publish
bus.publish(:my_event, { message: "hello" })

# Unsubscribe
bus.off(:my_event, subscription_id)
```

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

## Built-in Events

The UIController automatically handles these events:

- `:user_message` - User input message
- `:assistant_message` - Assistant response
- `:tool_call` - Tool execution start
- `:tool_result` - Tool execution result
- `:tool_error` - Tool execution error
- `:thinking` - Thinking indicator
- `:status_update` - Status bar update

## Keyboard Shortcuts

- **Enter** - Submit input
- **Ctrl+C** - Exit
- **Ctrl+L** - Clear output
- **Ctrl+U** - Clear input line
- **Up/Down** - Scroll output (when input empty) or navigate history
- **Left/Right** - Move cursor in input
- **Home/End** - Jump to start/end of input
- **Backspace** - Delete character before cursor
- **Delete** - Delete character at cursor

## Layout Structure

```
┌────────────────────────────────────────┐
│         Output Area (Scrollable)       │ ← Lines 0 to height-4
│  [<<] Assistant: Hello...              │
│  [=>] Tool: file_reader                │
│  [<=] Result: ...                      │
│  ...                                   │
├────────────────────────────────────────┤ ← Separator
│ [>>] Input: _                          │ ← Input line
├────────────────────────────────────────┤ ← Status bar
│ [Info] Status information              │
└────────────────────────────────────────┘
```

## Demo

Run the included demo:

```bash
ruby examples/ui2_demo.rb
```

Commands in demo:
- `/help` - Show help
- `/clear` - Clear output
- `/status` - Show status
- `/tools` - Demo tool rendering
- `/thinking` - Demo thinking indicator
- `/scroll` - Generate scrollable content
- `/quit` - Exit

## Integration with Business Logic

```ruby
# In your business logic (Agent, Tool, etc.)
# Just publish events - no UI code!

event_bus.publish(:tool_call, {
  tool_name: "web_search",
  formatted_call: "web_search(query: 'Ruby patterns')"
})

# Simulate work
result = perform_search(query)

event_bus.publish(:tool_result, {
  result: "Found 10 results"
})
```

The UIController will automatically render these events to the screen.

## Testing

Tests are included for all core components:

```bash
bundle exec rspec spec/ui2/
```

## Design Principles

1. **Separation of Concerns**: Business logic never calls UI code directly
2. **Event-Driven**: All communication through EventBus
3. **Component-Based**: Reusable, testable UI components
4. **Responsive**: Handles terminal resize and edge cases
5. **Extensible**: Easy to add new components and events

## Future Enhancements

- Multi-panel layouts (sidebar, tabs)
- Mouse support
- Custom themes
- Syntax highlighting
- Advanced text formatting (tables, lists)
- Plugin system for custom components

## License

MIT
