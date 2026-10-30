# frozen_string_literal: true

RSpec.describe "Scheduled tasks page UI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)    { File.read(File.join(web_dir, "features/tasks/view.js")) }
  let(:store)   { File.read(File.join(web_dir, "features/tasks/store.js")) }
  let(:html)    { File.read(File.join(web_dir, "index.html")) }
  let(:styles)  { File.read(File.join(web_dir, "app.css")) }

  it "has scheduled / run-history tabs and a shared search box" do
    expect(html).to include('data-tab="tasks" data-i18n="tasks.tab.tasks"')
    expect(html).to include('data-tab="runs" data-i18n="tasks.tab.runs"')
    expect(html).to include('id="tasks-search-input"')
    expect(html).to include('<div id="task-runs-table" style="display:none"></div>')
    expect(view).to include("_matches(t.name) || _matches(t.content)")
    expect(view).to include("_matches(r.task) || _matches(r.error)")
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

  it "opens the full prompt in a modal instead of expanding the card" do
    expect(view).to include("_openDetail(t)")
    expect(view).to include("modal-box lg task-detail-modal")
    expect(view).to include('class="modal-body"')
    expect(view).not_to include("task-card-detail")
    expect(styles).to include(".task-detail-modal .modal-body {")
    expect(styles).not_to include(".task-card-detail")
  end
end
