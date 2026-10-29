# frozen_string_literal: true

# The recycle bin splits into "Agent Files" and "Sessions". Those two used to be
# underline page tabs; they are now a segmented control, so the styles must come
# from the shared component rather than from local tab rules.
RSpec.describe "Recycle bin tab switcher" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:html)    { File.read(File.join(web_dir, "index.html")) }
  let(:view_js) { File.read(File.join(web_dir, "features/trash/view.js")) }
  let(:css)     { File.read(File.join(web_dir, "app.css")) }
  let(:i18n_js) { File.read(File.join(web_dir, "i18n.js")) }

  # The tab bar markup, cut out of index.html.
  def tab_bar
    match = html[/<div id="trash-tabs">.*?<\/div>\s*<\/div>/m]
    raise "trash tab bar not found" unless match

    match
  end

  it "renders the two tabs as a shared segmented control" do
    bar = tab_bar

    expect(bar).to include('<div class="segmented-control">')
    expect(bar.scan("trash-tab segmented-control__btn").size).to eq(2)
    expect(bar).not_to include("page-tab")
    expect(bar).not_to include("trash-tabs-left")
  end

  it "keeps the file and session panes addressed by data-tab" do
    %w[file-trash session-trash].each do |tab|
      expect(tab_bar).to match(/data-tab="#{tab}"/)
    end
  end

  it "lists the sessions pill before the files pill" do
    bar = tab_bar

    expect(bar.index('data-tab="session-trash"')).to be < bar.index('data-tab="file-trash"')
  end

  it "marks the active pill through the same button class the view toggles" do
    expect(tab_bar).to match(/class="trash-tab segmented-control__btn active"[^>]*data-tab="session-trash"/)
    expect(view_js).to match(
      /document\.querySelectorAll\("\.trash-tab"\)\.forEach\(btn => \{\s+btn\.classList\.toggle\("active", btn\.dataset\.tab === tab\);/
    )
    expect(view_js).not_to include("page-tab")
  end

  it "opens on the sessions tab" do
    expect(view_js).to match(
      /onPanelShow\(\) \{\s+_wire\(\);\s+_activeTab = null;\s+(?:\/\/[^\n]*\n\s+)?_switchTab\("session-trash"\);/
    )
    # The markup ships in the same state as the switch, so the first paint is
    # already the sessions pane instead of flashing the file list.
    expect(html).to match(/<div id="trash-tab-file" class="trash-tab-content" style="display:none">/)
    expect(html).to match(/<div id="trash-tab-session" class="trash-tab-content">/)
    expect(html).not_to match(/id="trash-filter-bar"[^>]*style="display:none"/)
    expect(html).not_to match(/id="trash-session-hint"[^>]*style="display:none"/)
    expect(html).to match(/id="btn-trash-empty-orphans"[^>]*style="display:none"/)
  end

  it "scrolls the hint, toolbar and list as one region under the pills" do
    scroll = html[%r{<div id="trash-scroll">.*?</div>\s*</div>\s*</div>\s*<!--}m]
    raise "trash scroll region not found" unless scroll

    expect(scroll).to include('id="trash-session-hint"')
    expect(scroll).to include('class="trash-toolbar"')
    expect(scroll).to include('id="trash-tab-file"')
    expect(scroll).to include('id="trash-tab-session"')
    # The tab strip stays outside it, so only the region below the pills moves.
    expect(html.index('id="trash-tabs"')).to be < html.index('id="trash-scroll"')

    expect(css).to match(/#trash-body \{[^}]*overflow: hidden;/m)
    expect(css).to match(/#trash-scroll \{[^}]*overflow-y: auto;/m)
    # The region below the pills owns the spacing now, so #trash-body must not
    # add a gap of its own or the strip floats away from the tab strip.
    expect(css).not_to match(/#trash-body \{[^}]*\bgap:/m)
    # The room under the pills lives on the scroll box, so the files tab (whose
    # first row is the toolbar, no hint) gets the same spacing as the sessions
    # tab. The hint only tightens the gap below it.
    expect(css).to match(/#trash-scroll \{[^}]*padding: 0\.5rem 2\.25rem 0 0;/m)
    expect(css).to match(/\.trash-session-hint \{[^}]*margin: 0 0 -0\.25rem;/m)
    expect(css).to match(/#trash-scroll \{[^}]*margin-right: -2\.25rem;/m)
    expect(css).to match(/\.trash-tab-content \{[^}]*margin-top: -0\.625rem;/m)
    expect(css).not_to match(/\.trash-tab-content \{[^}]*overflow-y/m)
  end

  it "drops the retired underline styles" do
    expect(css).not_to include(".trash-tabs-left")
    expect(css).not_to match(/^\.trash-tab\s*\{/m)
    expect(css).to match(/#trash-tabs \{\n\s+display: flex;\n\s+margin-bottom: 0\.25rem;\n\}/)
  end

  it "styles the pills once, in the shared component" do
    expect(css).to match(/\.segmented-control \{/)
    expect(css).to match(/\.segmented-control__btn\.active \{/)
    expect(css.scan(/^\.segmented-control \{/m).size).to eq(1)
  end

  it "translates both tab labels in both locales" do
    %w[trash.tabFile trash.tabSession].each do |key|
      expect(i18n_js.scan(%("#{key}":)).size).to eq(2)
    end
  end

  it "names the Chinese tabs 文件 and 会话, not 文件回收 / 会话回收" do
    # The page is already called 回收站, so repeating 回收 on both pills below it
    # was noise; the labels now match the English pair (Agent Files / Sessions).
    expect(i18n_js).to match(/"trash\.tabFile":\s+"文件",/)
    expect(i18n_js).to match(/"trash\.tabSession":\s+"会话",/)
    expect(i18n_js).not_to include("文件回收")
    expect(i18n_js).not_to include("会话回收")
  end
end
