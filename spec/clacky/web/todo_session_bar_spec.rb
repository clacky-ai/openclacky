# frozen_string_literal: true

RSpec.describe "Session-bar task list" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:html) { File.read(File.join(web_dir, "index.html")) }
  let(:sessions) { File.read(File.join(web_dir, "sessions.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }
  let(:i18n) { File.read(File.join(web_dir, "i18n.js")) }

  it "keeps a compact task-list anchor in the session bar" do
    expect(html).to include('id="todo-trigger"')
    expect(html).to include('id="todo-popover"')
    expect(html).not_to include('id="sib-tasks"')
    expect(styles).to match(/\.todo-trigger \{.*?width: 1\.375rem;/m)
    expect(styles).to match(/\.todo-panel\.has-todos \.todo-trigger-detail \{/)
  end

  it "runs model, permission mode, task list, then latency" do
    expect(html).to match(
      /id="sib-model-wrap".*?id="sib-mode-wrap".*?sib-sep-after-mode.*?id="todo-panel".*?sib-sep-after-todo.*?id="sib-signal-wrap"/m
    )
    expect(html).not_to include("sib-reasoning-wrap")
  end

  it "draws the permission mode as the same pill the model picker uses" do
    expect(html).to include('id="sib-mode" class="sib-mode-clickable"')
    expect(html).to include('<span class="sib-pill-label" data-i18n="sib.mode.pill">')
    expect(html).to include('id="sib-mode-text"')
    expect(styles).to match(/#session-info-bar \.sib-mode-clickable \{.*?border-radius: 999px;/m)
    expect(styles).to match(/#sib-model-wrap,\n#sib-mode-wrap \{/)
    expect(i18n).to include('"sib.mode.pill":  "权限"')
    expect(i18n).to include('"sib.mode.pill":  "Mode"')
  end

  it "keeps the pill label when the mode changes" do
    expect(sessions).to include("const sibModeText = $(\"sib-mode-text\");")
    expect(sessions).to include("sibModeText.textContent = I18n.t(`sib.mode.${mode}`);")
    expect(sessions).not_to include('sibMode.textContent = I18n.t(`sib.mode.${mode}`) + " ▾"')
  end

  it "flips the permission caret while its menu is open" do
    expect(sessions).to include('modeButton.classList.toggle("is-open", open);')
    expect(sessions).to include('modeButton.classList.remove("is-open");')
    expect(styles).to match(/\.sib-mode-clickable\.is-open \.sib-caret \{\n  transform: rotate\(180deg\);/)
    expect(styles).to match(/\.sib-mode-clickable \.sib-caret \{\n  pointer-events: none;/)
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
