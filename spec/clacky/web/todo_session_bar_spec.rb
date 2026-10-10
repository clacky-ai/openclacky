# frozen_string_literal: true

RSpec.describe "Session-bar task list" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:html) { File.read(File.join(web_dir, "index.html")) }
  let(:sessions) { File.read(File.join(web_dir, "sessions.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }

  it "keeps a compact task-list anchor in the session bar" do
    expect(html).to include('id="todo-trigger"')
    expect(html).to include('id="todo-popover"')
    expect(html).not_to include('id="sib-tasks"')
    expect(styles).to match(/\.todo-trigger \{.*?width: 1\.375rem;/m)
    expect(styles).to match(/\.todo-panel\.has-todos \.todo-trigger-detail \{/)
  end

  it "expands for any non-empty list and disables the empty state" do
    expect(sessions).to include("const hasTodos = !!sid && todos.length > 0;")
    expect(sessions).to include("trigger.disabled = !hasTodos;")
    expect(sessions).to include('panel.classList.toggle("has-todos", hasTodos);')
    expect(sessions).not_to include("clacky-todo-collapsed")
  end

  it "opens the list in an upward fixed popover" do
    expect(styles).to match(/\.todo-popover \{.*?position: fixed;.*?max-height: min\(24rem,.*?transform: translate\(-50%, -100%\);/m)
    expect(sessions).to include("Sessions._setTodoPopoverOpen(")
    expect(sessions).to include("Sessions._positionTodoPopover();")
  end

  it "keeps the header on one line and reveals overflowing tasks on hover" do
    expect(html).to include('class="todo-popover-heading"')
    expect(styles).to match(/\.todo-popover-heading \{.*?white-space: nowrap;/m)
    expect(styles).to match(/\.todo-text \{.*?mask-image: linear-gradient/m)
    expect(sessions).to include('activeClass: "todo-text-scrolling"')
  end
end
