# frozen_string_literal: true

# The changes panel toolbar is a single row of icon buttons: layout, expand,
# the file-tree toggle and refresh on the far right. The layout button cycles
# through the three modes on click (no dropdown), and the tree button collapses
# the file list so the diff stream gets the whole width.
RSpec.describe "Git panel toolbar" do
  let(:view) do
    File.read(File.expand_path("../../../lib/clacky/default_extensions/git/panels/git/view.js", __dir__))
  end

  it "cycles the diff layout on click instead of opening a menu" do
    expect(view).not_to include("openLayoutMenu")
    expect(view).not_to include("layoutMenu")

    cycle = view[/function cycleLayout\(\) \{.*?\n  \}/m]
    expect(cycle).to include("LAYOUT_MODES[(LAYOUT_MODES.indexOf(state.layout) + 1) % LAYOUT_MODES.length]")

    mount = view[/layoutBtn\.addEventListener\("click".*?\);/m]
    expect(mount).to include("cycleLayout")
  end

  it "draws the layout icon with diff-coloured panes" do
    expect(view).to include("--cg-swatch-add")
    expect(view).to include("--cg-swatch-del")
    %w[ICON_LAYOUT_AUTO ICON_LAYOUT_SPLIT ICON_LAYOUT_UNIFIED].each do |icon|
      expect(view[/const #{icon} = '[^']+'/]).to include("var(--cg-swatch-")
    end
    auto = view[/const ICON_LAYOUT_AUTO = '[^']+'/]
    expect(auto).to include("polygon")
  end

  it "toggles the file tree and remembers the choice" do
    toggle = view[/function setTreeVisible\(visible\) \{.*?\n  \}/m]
    expect(toggle).to include("localStorage.setItem(TREE_KEY")
    expect(toggle).to include("applyTreeButton()")

    apply = view[/function applyTreeButton\(\) \{.*?\n  \}/m]
    expect(apply).to include('els.root.classList.toggle("is-tree-hidden"')
    expect(apply).to include('btn.classList.toggle("is-on", state.treeVisible)')

    rule = view[/\.changes-root\.is-tree-hidden \.cg-side,[^{]*\{[^}]*\}/]
    expect(rule).to include("display: none")
  end

  it "keeps the refresh button at the far right of the bar" do
    bar = view[/const bar = el\("div", \{ class: "cg-bar" \},.*?\);/m]
    expect(bar).to include("layoutBtn, expandBtn, treeBtn, refreshBtn")
  end

  it "draws the expand-all button as paired arrows beside indented rules" do
    icon = view[/const ICON_EXPAND_ALL = '[^']+'/]
    expect(icon).to include("M6.6 7.4l2.2 2.2 2.2-2.2")
    expect(icon).to include("M6.6 16.6l2.2-2.2 2.2 2.2")
    expect(view).to include("expandBtn.innerHTML = ICON_EXPAND_ALL")
  end

  it "drops the copy-patch action" do
    expect(view).not_to include("copyPatch")
    expect(view).not_to include("changes.copy")
  end
end
