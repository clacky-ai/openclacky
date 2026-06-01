# frozen_string_literal: true

require "spec_helper"

if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("2.6.0")
  RSpec.describe "Clacky::RichUIController" do
    it "is not supported on Ruby older than 2.6" do
      skip "ruby_rich requires Ruby >= 2.6"
    end
  end
else
require_relative "../../lib/clacky/rich_ui_controller"

RSpec.describe Clacky::RichUIController do
  describe "layout" do
    it "shows a right-side todos panel next to the transcript" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.shell.layout.calculate_dimensions(100, 30)

      expect(ui.shell.layout[:sidebar]).to be_nil
      expect(ui.shell.layout[:todos]).not_to be_nil
      expect(ui.shell.layout[:todos].width).to eq(36)
      expect(ui.shell.layout[:transcript].width).to eq(64)
      rendered_text = strip_ansi(ui.shell.layout.render)
      expect(rendered_text).to include("Todos")
      expect(rendered_text).not_to include("Plan")
    end

    it "renders todo_manager tasks in the right-side todos panel" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.update_todos([
        { content: "Research DeepSeek v4", status: "pending" },
        { content: "Write weather scraper", status: "in_progress" },
        { content: "Optimize SQL query", status: "completed" }
      ])
      ui.shell.layout.calculate_dimensions(100, 30)

      rendered_text = strip_ansi(ui.shell.layout.render)
      expect(rendered_text).to include("Todos")
      expect(rendered_text).to include("Research DeepSeek v4")
      expect(rendered_text).to include("Write weather scraper")
      expect(rendered_text).to include("Optimize SQL query")
      expect(rendered_text).not_to match(/\b1\s+✓/)
      expect(rendered_text).not_to match(/\b1\s+●/)
      expect(rendered_text).not_to match(/\b1\s+○/)
    end

    it "shows tool activity in the todos panel when todo_manager has not created todos" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.show_tool_call("web_search", { query: "普京访华 2025最新消息" })
      ui.show_tool_call("web_fetch", { url: "https://www.chinadaily.com.cn/a/202505/01/example.html" })
      ui.shell.layout.calculate_dimensions(100, 30)

      rendered_text = strip_ansi(ui.shell.layout.render)
      expect(rendered_text).to include("Todos")
      expect(ui.shell.sidebar.tasks.map { |task| task[:label] }).to include(
        'web_search("普京访华 2025最新消息")',
        "web_fetch(www.chinadaily.com.cn)"
      )
      expect(rendered_text).not_to include("No active todos")
    end

    it "keeps explicit todo_manager tasks ahead of tool activity" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.show_tool_call("web_fetch", { url: "https://example.com" })
      ui.update_todos([{ content: "Collect release notes", status: "in_progress" }])
      ui.shell.layout.calculate_dimensions(100, 30)

      rendered_text = strip_ansi(ui.shell.layout.render)
      expect(rendered_text).to include("Collect release notes")
      expect(ui.shell.sidebar.tasks.map { |task| task[:label] }).to eq(["Collect release notes"])
    end

    it "clears the todos panel after explicit todo_manager tasks are completed" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.show_tool_call("web_fetch", { url: "https://example.com" })
      ui.update_todos([{ content: "Collect release notes", status: "in_progress" }])
      ui.update_todos([])
      ui.shell.layout.calculate_dimensions(100, 30)

      rendered_text = strip_ansi(ui.shell.layout.render)
      expect(ui.shell.sidebar.tasks).to eq([])
      expect(rendered_text).to include("No active todos")
    end
  end

  describe "RubyRich IME cursor integration" do
    it "keeps RubyRich input rendering free of fake inverse cursor cells" do
      editor = RubyRich::LineEditor.new
      editor.insert("hi")

      rendered = editor.render_lines(width: 20, focused: true).join

      expect(rendered).to eq("hi")
      expect(rendered).not_to include("\e[7m")
    end

    it "reports the composer cursor position for native terminal cursor placement" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      ui.shell.layout.calculate_dimensions(100, 30)
      ui.shell.layout.render

      ui.shell.composer.editor.insert("hi")

      expect(ui.shell.composer.native_cursor_position).to eq([0, 4])
    end

    it "leaves RubyRich terminal cursor visible by default" do
      source = File.read(RubyRich::Terminal.method(:setup).source_location.first)
      expect(source).to include("def setup(mouse: false, hide_cursor: false")
    end

    it "starts RubyRich agent shells in the alternate screen by default" do
      source = File.read(RubyRich::AgentShell.instance_method(:start).source_location.first)
      expect(source).to include("def start(refresh_rate: 24, mouse: true, alt_screen: true)")
    end

    it "keeps empty escape from desynchronizing composer focus" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.shell.layout.notify_listeners(type: :key, name: :escape)
      ui.shell.layout.notify_listeners(type: :key, name: :string, value: "x")

      expect(ui.shell.focus_manager.focused_name).to eq(:composer)
      expect(ui.shell.composer).to be_focused
      expect(ui.shell.composer.value).to eq("x")
    end

    it "switches focus through the focus manager when clicking transcript and composer" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      ui.shell.layout.calculate_dimensions(100, 30)

      ui.shell.layout.notify_listeners(type: :mouse, name: :mouse_down, x: 2, y: 2, button: :left)

      expect(ui.shell.focus_manager.focused_name).to eq(:transcript)
      expect(ui.shell.composer).not_to be_focused

      ui.shell.layout.notify_listeners(type: :mouse, name: :mouse_down, x: 2, y: 24, button: :left)

      expect(ui.shell.focus_manager.focused_name).to eq(:composer)
      expect(ui.shell.composer).to be_focused
    end

    it "keeps composer focus when clicking non-focusable chrome" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      ui.shell.layout.calculate_dimensions(100, 30)

      ui.shell.layout.notify_listeners(type: :mouse, name: :mouse_down, x: 70, y: 2, button: :left)

      expect(ui.shell.focus_manager.focused_name).to eq(:composer)
      expect(ui.shell.composer).to be_focused
    end

    it "restores composer focus from any visible composer row" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      ui.shell.layout.calculate_dimensions(100, 30)

      (24..28).each do |y|
        ui.shell.focus_manager.focus(:transcript)
        ui.shell.layout.notify_listeners(type: :mouse, name: :mouse_down, x: 2, y: y, button: :left)

        expect(ui.shell.focus_manager.focused_name).to eq(:composer)
        expect(ui.shell.composer).to be_focused
      end
    end

    it "emits a generic mouse target event before component mouse handlers consume the click" do
      root = RubyRich::Layout.new(name: :root)
      root.split_column(
        RubyRich::Layout.new(name: :top, size: 3),
        RubyRich::Layout.new(name: :bottom, size: 3)
      )
      root.calculate_dimensions(20, 6)
      targets = []

      root.key(:mouse_target, 100) do |event, _live|
        targets << event[:target_layout].name
        false
      end
      root[:bottom].key(:mouse_down, 100) { true }

      root.notify_listeners(type: :mouse, name: :mouse_down, x: 2, y: 4, button: :left)

      expect(targets).to eq([:bottom])
    end

    it "scrolls the transcript with the mouse wheel even when composer has focus" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      80.times { |index| ui.shell.add_markdown("line #{index}") }
      ui.shell.layout.calculate_dimensions(100, 30)
      ui.shell.focus_manager.focus(:composer)
      ui.shell.viewport.scroll_to(20)

      ui.shell.layout.notify_listeners(type: :mouse, name: :mouse_wheel, x: 2, y: 2, direction: :down, button: :wheel)

      expect(ui.shell.viewport.scroll_top).to be > 20
      expect(ui.shell.focus_manager.focused_name).to eq(:composer)
    end

    it "selects transcript text by dragging the viewport content and copies it on right click" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      ui.shell.transcript.add_block(:markdown, (0...80).map { |index| "line #{index}" }.join("\n"), metadata: { plain: true })
      ui.shell.layout.calculate_dimensions(100, 30)
      ui.shell.focus_manager.focus(:composer)
      ui.shell.viewport.scroll_to(20)

      expect(ui.shell.viewport).to receive(:copy_to_clipboard).with("line 29").once.and_return(true)

      ui.shell.layout.notify_listeners(type: :mouse, name: :mouse_down, x: 0, y: 10, button: :left)
      ui.shell.layout.notify_listeners(type: :mouse, name: :mouse_drag, x: 7, y: 10, button: :left)
      ui.shell.layout.notify_listeners(type: :mouse, name: :mouse_up, x: 7, y: 10, button: :left)
      expect(ui.shell.viewport.selected_text).to eq("line 29")

      ui.shell.layout.notify_listeners(type: :mouse, name: :mouse_down, x: 7, y: 10, button: :right)

      expect(ui.shell.viewport.selected_text).to eq("")
      expect(ui.shell.viewport.scroll_top).to eq(20)
      expect(ui.shell.focus_manager.focused_name).to eq(:transcript)
    end

    it "falls back to OSC 52 terminal clipboard when platform clipboard commands are unavailable" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      allow(RubyRich::Terminal).to receive(:windows?).and_return(false)
      allow($stdout).to receive(:print)
      allow($stdout).to receive(:flush)

      ClimateControl.modify("WAYLAND_DISPLAY" => nil, "DISPLAY" => nil) do
        expect(ui.shell.viewport.send(:copy_to_clipboard, "line 29")).to be true
      end

      expect($stdout).to have_received(:print).with("\e]52;c;bGluZSAyOQ==\a")
      expect($stdout).to have_received(:flush)
    end

    it "does not highlight padded viewport whitespace after selected text" do
      viewport = RubyRich::Viewport.new
      viewport.instance_variable_set(:@selection_start, { line: 0, col: 0 })
      viewport.instance_variable_set(:@selection_end, { line: 0, col: 20 })

      highlighted = viewport.send(:apply_selection, "hello     ", 0)

      expect(highlighted).to include("#{RubyRich::AnsiCode.inverse}hello#{RubyRich::AnsiCode.reset}")
      expect(highlighted).to end_with("     ")
    end

    it "keeps selection highlighting across ANSI style resets" do
      viewport = RubyRich::Viewport.new
      viewport.instance_variable_set(:@selection_start, { line: 0, col: 0 })
      viewport.instance_variable_set(:@selection_end, { line: 0, col: 9 })

      highlighted = viewport.send(:apply_selection, "ab#{RubyRich::AnsiCode.reset}cd", 0)

      expect(highlighted).to include("#{RubyRich::AnsiCode.reset}#{RubyRich::AnsiCode.inverse}cd")
    end
  end

  describe "#stop" do
    it "clears the terminal when requested" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      expect(ui.shell).to receive(:stop)
      expect(RubyRich::Terminal).to receive(:clear)

      ui.stop(clear_screen: true)
    end
  end

  describe "Ctrl+C handling" do
    it "consumes one keypress so non-empty input clears before the next Ctrl+C exits" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      live = instance_double("RubyRich::Live")
      interrupts = []

      expect(live).not_to receive(:stop)
      allow(ui.shell.layout.root).to receive(:live).and_return(live)

      ui.on_interrupt do |input_was_empty:|
        interrupts << input_was_empty
        ui.clear_input unless input_was_empty
      end

      ui.shell.composer.editor.insert("draft")
      ui.shell.layout.notify_listeners(type: :key, name: :ctrl_c)

      expect(interrupts).to eq([false])
      expect(ui.shell.composer.value).to eq("")

      ui.shell.layout.notify_listeners(type: :key, name: :ctrl_c)

      expect(interrupts).to eq([false, true])
    end
  end

  describe "#initialize_and_show_banner" do
    it "shows the full startup welcome banner" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.initialize_and_show_banner

      entry = ui.shell.transcript.store.entries.last
      expect(entry.type).to eq(:markdown)
      expect(entry.metadata[:plain]).to eq(true)
      expect(entry.content).to include("Your personal Assistant & Technical Co-founder")
      expect(entry.content).to include("AGENT MODE INITIALIZED")
      expect(entry.content).to include("[Working Directory]")
      expect(ui.shell.transcript.render.join("\n")).to include("[*] Ask questions")
      expect(entry.content).not_to eq("OpenClacky is ready.")
    end
  end

  describe "#show_assistant_message" do
    it "adds assistant content as markdown so RubyRich renders headings, lists, code, and tables" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.show_assistant_message(<<~MARKDOWN, files: [])
        <think>hidden reasoning</think>

        ## Result

        - `one`
        - **two**
      MARKDOWN

      entry = ui.shell.transcript.store.entries.last
      expect(entry.type).to eq(:markdown)
      expect(entry.content).to include("## Result")
      expect(entry.content).to include("- **two**")
      expect(entry.content).not_to include("hidden reasoning")
    end

    it "adds attached files as a compact markdown list" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")

      ui.show_assistant_message("Done", files: [{ path: "README.md" }, { "name" => "notes.txt" }])

      entries = ui.shell.transcript.store.entries
      expect(entries.map(&:type)).to eq([:markdown, :markdown])
      expect(entries.last.content).to eq("**Files**\n\n- `README.md`\n- `notes.txt`")
    end

    it "streams long assistant markdown into a single transcript entry" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      allow(ui).to receive(:sleep)
      content = "这是一个很长的故事。" * 40

      ui.show_assistant_message(content, files: [])
      ui.instance_variable_get(:@stream_threads).each(&:join)

      entries = ui.shell.transcript.store.entries
      expect(entries.size).to eq(1)
      expect(entries.last.type).to eq(:markdown)
      expect(entries.last.content).to eq(content)
    end

    it "wraps markdown table cells to fit the transcript content width" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      ui.show_assistant_message(<<~MARKDOWN, files: [])
        | Column A | Column B | Column C |
        | --- | --- | --- |
        | veryveryveryveryveryverylong | another very very very long value | 中文中文中文中文中文中文 |
      MARKDOWN

      ui.shell.transcript.width = 40
      lines = ui.shell.transcript.render
      table_lines = lines.select { |line| line.gsub(/\e\[[0-9;:]*m/, "").include?("│") }

      expect(table_lines).not_to be_empty
      expect(table_lines.map { |line| visible_width(line) }.max).to be <= 39
    end

    it "wraps long unbroken English transcript lines" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      ui.show_assistant_message("a" * 80, files: [])

      ui.shell.viewport.width = 20
      ui.shell.viewport.height = 10
      lines = ui.shell.viewport.render.reject { |line| line.strip.empty? }

      expect(lines.length).to be > 1
      expect(lines.map { |line| visible_width(line.rstrip) }.max).to be <= 20
    end

    it "wraps long unbroken Chinese transcript lines" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      ui.show_assistant_message("中文" * 30, files: [])

      ui.shell.viewport.width = 20
      ui.shell.viewport.height = 10
      lines = ui.shell.viewport.render.reject { |line| line.strip.empty? }

      expect(lines.length).to be > 1
      expect(lines.map { |line| visible_width(line.rstrip) }.max).to be <= 20
    end

    it "does not stretch inline-code background across markdown table cell padding" do
      ui = described_class.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test-model")
      ui.show_assistant_message(<<~MARKDOWN, files: [])
        | Runtime | Detail |
        | --- | --- |
        | Async | `tokio` and `ratatui` |
      MARKDOWN

      ui.shell.transcript.width = 60
      rendered = ui.shell.transcript.render.join("\n")

      expect(rendered).to include("tokio")
      expect(rendered).not_to include("\e[47m")
      expect(rendered).not_to include("\e[37m")
    end
  end

  def visible_width(line)
    line.gsub(/\e\[[0-9;:]*m/, "").display_width
  end

  def strip_ansi(text)
    text.gsub(/\e\[[0-9;]*m/, "")
  end

  describe Clacky::RichUIController::ConfigMenuDialog do
    it "renders a selectable model configuration menu" do
      dialog = described_class.new(
        choices: [
          { label: "[default] deepseek-v4-pro (sk-31e...b5ee)", value: { action: :switch }, current: true },
          { label: "─" * 50, disabled: true },
          { label: "[+] Add New Model", value: { action: :add } },
          { label: "[*] Edit Current Model", value: { action: :edit } },
          { label: "[X] Close", value: { action: :close } }
        ],
        selected_index: 0
      )

      rendered_lines = dialog.render_to_buffer.map { |line| line.compact.join }
      rendered_text = strip_ansi(rendered_lines.join("\n"))

      expect(rendered_text).to include("Model Configuration")
      expect(rendered_text).to include("➜")
      expect(rendered_text).to include("[+] Add New Model")
      expect(rendered_text).to include("[*] Edit Current Model")
      expect(rendered_text).to include("[X] Close")
      expect(rendered_text).to include("Enter: Select")
    end

    it "skips disabled separators when navigating" do
      dialog = described_class.new(
        choices: [
          { label: "first", value: { action: :switch } },
          { label: "─" * 50, disabled: true },
          { label: "[+] Add New Model", value: { action: :add } }
        ],
        selected_index: 0
      )

      dialog.move_down

      expect(dialog.selected_choice[:label]).to eq("[+] Add New Model")
    end
  end

  describe Clacky::RichUIController::FormDialog do
    it "edits fields and returns keyed values" do
      dialog = described_class.new(
        title: "Edit Model",
        fields: [
          { name: :api_key, label: "API Key:", default: "", mask: true },
          { name: :model, label: "Model:", default: "" }
        ]
      )

      dialog.notify_listeners(type: :key, name: :string, value: "secret")
      dialog.notify_listeners(type: :key, name: :tab)
      dialog.notify_listeners(type: :key, name: :string, value: "new-model")
      dialog.notify_listeners(type: :key, name: :enter)

      expect(dialog.wait).to eq(api_key: "secret", model: "new-model")
    end

    it "renders masked values without exposing the raw API key" do
      dialog = described_class.new(
        title: "Edit Model",
        fields: [{ name: :api_key, label: "API Key:", default: "sk-secret", mask: true }]
      )

      rendered_text = strip_ansi(dialog.render_to_buffer.map { |line| line.compact.join }.join("\n"))

      expect(rendered_text).to include("*********")
      expect(rendered_text).not_to include("sk-secret")
    end
  end
end
end