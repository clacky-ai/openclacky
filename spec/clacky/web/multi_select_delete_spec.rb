# frozen_string_literal: true

require "open3"

RSpec.describe "Web sidebar bulk delete" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }

  it "selects and deletes multiple sessions from the sidebar" do
    script = File.expand_path("../../support/multi_select_delete_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end

  it "translates every bulk-delete string in both languages" do
    source = File.read(File.join(web_dir, "i18n.js"))
    keys = %w[
      sessions.actions.selectMultiple
      sessions.select.count
      sessions.select.countOf
      sessions.select.cancel
      sessions.select.delete
      sessions.select.confirmDelete
      sessions.select.deleteFailed
    ]
    keys.each do |key|
      expect(source.scan(/"#{Regexp.escape(key)}":/).size).to eq(2), "#{key} must exist in en + zh"
    end
  end

  it "scopes every selection rule to the sidebar so the search overlay is unaffected" do
    css = File.read(File.join(web_dir, "app.css"))
    unscoped = css.scan(/^\s*([^\n{]*\.selecting[^\n{]*)\{/).flatten
                  .reject { |sel| sel.include?("#sidebar-list.selecting") }
    expect(unscoped).to be_empty, "unscoped .selecting rules leak into the search overlay: #{unscoped}"
    expect(css).to include("#sidebar-list.selecting .session-actions-btn")
  end

  it "takes the denominator from the server, not from the paged-in rows" do
    source = File.read(File.join(web_dir, "i18n.js"))
    counts = source.scan(/"sessions\.select\.countOf": "([^"]*)"/).flatten
    expect(counts.size).to eq(2)
    counts.each { |text| expect(text).to include("{{n}}").and include("{{total}}") }

    js = File.read(File.join(web_dir, "sessions.js"))
    # Counting DOM rows would report the page size, not how many sessions exist.
    expect(js).not_to match(/querySelectorAll\([^)]*session-item[^)]*\)\.length/)
    expect(js).to match(/countOf",\s*\{\s*n: n,\s*total: _totalCount\s*\}/)
  end

  it "wires the server total through both list entry points" do
    dispatcher = File.read(File.join(web_dir, "ws-dispatcher.js"))
    expect(dispatcher).to match(/Sessions\.setAll\([^)]*ev\.total\)/),
                          "the initial WS session_list must hand its total to Sessions"

    js = File.read(File.join(web_dir, "sessions.js"))
    # "Load more" re-reports the total; without this the denominator freezes at
    # whatever the first page said.
    expect(js).to match(/_hasMore = !!data\.has_more;\s*\n\s*if \(data\.total/),
                  "loadMore must refresh _totalCount from the response"
  end

  it "reports a total alongside every paginated session list" do
    server = File.read(File.expand_path("../../../lib/clacky/server/http_server.rb", __dir__))
    expect(server.scan(/total: @registry\.total_count/).size).to eq(2),
                                                                "both the REST and WS list payloads must carry the total"

    registry = File.read(File.expand_path("../../../lib/clacky/server/session_registry.rb", __dir__))
    body = registry[/def total_count(.*?)\n      end/m, 1]
    expect(body).not_to be_nil
    # The denominator must not be narrowed by view/source/project filters: the
    # project tree stays tickable inside a folded group sub-view, so any
    # filtered count could end up smaller than what the user can select.
    # Counting behaviour itself is pinned in session_registry_spec.rb.
    expect(body).to include("all_sessions.size")
    expect(body).not_to match(/GROUPED_SOURCES|project_id|select|reject/)
  end

  it "keeps bulk delete out of the per-row ⋯ menu" do
    js = File.read(File.join(web_dir, "sessions.js"))

    # Bulk delete is a list-level action; offering it inside one row's menu
    # makes it look like it targets that row (PR review feedback). Exactly one
    # occurrence: the header menu's template (the negative lookbehind skips
    # the querySelector attribute string). A second one means the item
    # crept back into a row's ⋯ menu.
    expect(js.scan(/(?<!\[)data-action="selectMultiple"/).size).to eq(1)
  end

  it "enters selection mode via the header \"···\" menu, not from a session row" do
    html = File.read(File.join(web_dir, "index.html"))
    js   = File.read(File.join(web_dir, "sessions.js"))

    # Same affordance as the projects header: a bare "···" button that only
    # opens a menu, so the destructive-ish path needs a labelled second click.
    entry = html[/<button id="btn-sessions-menu".*?<\/button>/m]
    expect(entry).not_to be_nil
    expect(entry).to include("btn-icon-sm")
    expect(entry).to include("data-i18n-title=\"sessions.actions.selectMultiple\"")

    # The button opens the list menu; the menu's labelled item starts
    # selection, and a list-level entry never pre-ticks any row.
    expect(js).to match(/btn-sessions-menu"\);\s*\n\s*if \(sessionsMenuBtn\)/)
    expect(js).to match(/Sessions\._showListMenu\(sessionsMenuBtn\)/)
    expect(js).to match(/menu\.remove\(\);\s*\n\s*Sessions\.enterSelectMode\(\)/)
    expect(js).not_to include("enterSelectMode(session.id)")
    expect(js).not_to include("iconBulkTrash")

    # The menu item is the row-menu delete item verbatim — danger colour,
    # shared trash icon, escaped label — minus the top separator, so no
    # parallel styling exists.
    expect(js).to match(/_showListMenu\(anchor\) \{\s*\n\s*Sessions\._closeActionsMenu\(\)/)
    expect(js).to match(/className = "session-actions-menu"/)
    expect(js).to match(/session-actions-menu-item session-actions-menu-item--danger session-actions-menu-item--danger-follow" data-action="selectMultiple"/)
    expect(js).to match(/menu-icon">\$\{ICON_TRASH\}/)
    expect(js).to match(/menu-label">\$\{escapeHtml\(I18n\.t\("sessions\.actions\.selectMultiple"\)\)\}<\/span>/)
    expect(js.scan(/const ICON_TRASH/).size).to eq(1)
    css = File.read(File.join(web_dir, "app.css"))
    expect(css).to match(/\.session-actions-menu-item--danger-follow \{\s*\n\s*margin-top: 0;\s*\n\s*\}/)
    expect(css).to match(/--danger-follow::before \{\s*\n\s*content: none;\s*\n\s*\}/)

    # The header sits deep in the sidebar; a right-anchored menu (the
    # projects-organize style) runs off-screen at the minimum sidebar width.
    expect(js).not_to match(/menu\.style\.right = /)
    expect(js).to match(/if \(r\.left < 8\) menu\.style\.left = "8px"/)
    expect(js).to match(/r\.right > window\.innerWidth - 8/)
    expect(js).to match(/r\.bottom > window\.innerHeight - 8/)

    # Mid-selection the whole actions row (new session + this button) would
    # dead-end, so it must vanish while the list carries .selecting.
    css = File.read(File.join(web_dir, "app.css"))
    expect(css).to match(/#sidebar-list\.selecting #chat-section-header \.sidebar-divider-actions/)
  end

  it "keeps the cancel control a bordered text button, as signed off in the demo" do
    html = File.read(File.join(web_dir, "index.html"))
    bar = html[/<div id="session-select-bar".*?\n    <\/div>/m]
    expect(bar).not_to be_nil
    expect(bar).to include('data-i18n="sessions.select.cancel"')
    expect(bar[/data-select-cancel.*?<\/button>/m]).not_to include("<svg")

    css = File.read(File.join(web_dir, "app.css"))
    cancel = css[/\.select-bar-cancel \{(.*?)\}/m, 1]
    expect(cancel).to match(/border: 1px solid var\(--color-border-primary\)/)
  end

  it "relabels the bar when the user switches language mid-selection" do
    js = File.read(File.join(web_dir, "sessions.js"))
    # The counter and delete label are set imperatively, so a list re-render
    # alone leaves them stuck in the previous language.
    handler = js[/addEventListener\("langchange", \(\) => \{\s*\n\s*Sessions\.renderList\(\);(.*?)\}\);/m, 1]
    expect(handler).not_to be_nil, "the sidebar must still re-render on langchange"
    expect(handler).to include("_renderSelectBar()")
  end

  it "keeps mobile selection rules inside the main 768px block" do
    css = File.read(File.join(web_dir, "app.css"))
    start = css.index("@media (max-width: 768px) {\n")
    expect(start).not_to be_nil
    # The main responsive block is the only multi-line one; it closes at the
    # first `}` sitting alone in column 0.
    finish = css.index(/^\}$/, start)
    block = css[start...finish]
    expect(block).to include("#sidebar-list.selecting .session-item")
    expect(block).to include("#session-select-bar")
  end
end
