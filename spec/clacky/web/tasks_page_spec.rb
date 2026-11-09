# frozen_string_literal: true

require "open3"

RSpec.describe "Scheduled tasks page UI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)    { File.read(File.join(web_dir, "features/tasks/view.js")) }
  let(:store)   { File.read(File.join(web_dir, "features/tasks/store.js")) }
  let(:html)    { File.read(File.join(web_dir, "index.html")) }
  let(:styles)  { File.read(File.join(web_dir, "app.css")) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }

  it "has scheduled / run-history tabs and a shared search box" do
    expect(html).to include('data-tab="tasks" data-i18n="tasks.tab.tasks"')
    expect(html).to include('data-tab="runs" data-i18n="tasks.tab.runs"')
    expect(html).to include('id="tasks-search-input"')
    expect(html).to include('<div id="task-runs-table" style="display:none"></div>')
    expect(view).to include("_matches(t.title) || _matches(t.name) || _matches(t.content)")
    expect(view).to include("_matches(r.task) || _matches(_labelForTaskName(r.task)) || _matches(r.error)")
  end

  it "shows the display title and falls back to the plan name" do
    expect(view).to include("function _taskLabel(t) {")
    expect(view).to include("return t.title || t.name;")
    expect(view).to include("${escapeHtml(_taskLabel(t))}")
    expect(view).to include("escapeHtml(_labelForTaskName(r.task))")
    expect(view).to include('I18n.t("tasks.run.filtered", { name: _labelForTaskName(_runsTask) })')
  end

  it "renders a card grid filtered by enabled / paused" do
    expect(view).to include('grid.className = "task-card-grid"')
    expect(view).to include('card.className = "task-card"')
    expect(view).to include('"tasks.filter." + kind')
    expect(view).to include('I18n.t("tasks.section.paused")')
    expect(styles).to include(".task-card-grid {")
    expect(styles).to include(".segmented-control__count {")
    expect(view).to include('bar.className = "segmented-control"')
    expect(styles).not_to include(".task-section-empty")
  end

  it "lists active plans first, newest first inside each group" do
    expect(view).to include("function _isPaused(t) {")
    expect(view).to include("function _createdAt(t) {")
    expect(view).to include("function _sortTasks(tasks) {")
    expect(view).to include("_sortTasks(shown).forEach")
  end

  it "shows the next run on each card" do
    expect(view).to include("_nextRunLabel(t.next_run)")
    expect(view).to include("task-card-next")
    expect(styles).to include(".task-card.is-paused {")
  end

  it "puts run and edit on the card and the rest into the … menu" do
    expect(view).to include("task-card-tool task-btn-run")
    expect(view).to include("task-card-tool task-btn-edit")
    expect(view).to include('items.push(["history", "tasks.btn.history"])')
    expect(view).to include('else if (kind === "del")                        Tasks.delete(t.name);')
  end

  it "hints the run and edit buttons through the shared tooltip" do
    expect(view).to include(%(task-btn-run" data-tooltip="${escapeHtml(I18n.t("tasks.btn.run"))}" data-i18n-tooltip="tasks.btn.run"))
    expect(view).to include(%(task-btn-edit" data-tooltip="${escapeHtml(I18n.t("tasks.btn.edit"))}" data-i18n-tooltip="tasks.btn.edit"))
    expect(view).not_to include(%(task-btn-run" title=))
    expect(view).not_to include(%(task-btn-edit" title=))
  end

  it "loads run history from the API and opens the run's session" do
    expect(store).to include('fetch("/api/cron-runs")')
    expect(view).to include('Router.navigate("session", { id: r.session_id })')
  end

  it "offers starter examples in the empty state and sends their prompt to the AI" do
    expect(view).to include("function _renderEmptyState()")
    expect(view).to include('class="task-example" data-example="${ex.id}"')
    expect(view).to include('Tasks.createInSession(I18n.t("tasks.examples." + ex.id + ".prompt"))')
    expect(store).to include("createInSession(prompt)")
    expect(store).to include("`/cron-task-creator ${command}`")
    expect(styles).to include(".task-examples-grid {")
    expect(styles).to include(".task-example:hover {")

    %w[news daily weekly standup competitor words story why parents checkup].each do |id|
      %w[title desc prompt].each do |field|
        key = %("tasks.examples.#{id}.#{field}")
        expect(i18n.scan(key).length).to eq(2), "#{key} must exist in both locales"
      end
    end
    expect(i18n).to include("发送到我的飞书", "发送到我的钉钉")
  end

  it "opens the full prompt in a modal instead of expanding the card" do
    expect(view).to include("_openDetail(t)")
    expect(view).to include("modal-box lg task-detail-modal")
    expect(view).to include('class="modal-body"')
    expect(view).not_to include("task-card-detail")
    expect(styles).to include(".task-detail-modal .modal-body {")
    expect(styles).not_to include(".task-card-detail")
  end

  it "boots onPanelShow without a ReferenceError" do
    script = File.expand_path("../../support/tasks_view_boot_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
