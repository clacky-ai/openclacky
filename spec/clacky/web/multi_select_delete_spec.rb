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

  it "draws no extra separator between the two delete entries" do
    js  = File.read(File.join(web_dir, "sessions.js"))
    css = File.read(File.join(web_dir, "app.css"))
    entry = js[/<div class="([^"]*)" data-action="selectMultiple">/, 1]
    expect(entry).to include("session-actions-menu-item--danger-follow")
    expect(css).to match(/\.session-actions-menu-item--danger-follow::before \{\s*content: none;/)
  end

  it "reuses the existing trash icon instead of inventing a second one" do
    js = File.read(File.join(web_dir, "sessions.js"))
    menu = js[/data-action="selectMultiple">(.*?)<\/div>/m, 1]
    expect(menu).to include("${iconTrash}")
    expect(js).not_to include("iconBulkTrash")
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
