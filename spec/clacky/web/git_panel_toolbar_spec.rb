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
    expect(bar).to include("layoutBtn, expandBtn, treeBtn, findBtn, refreshBtn")
  end

  it "keeps the toolbar icons optically the same size" do
    # The artwork bounds differ inside the 24 grid (roughly 15-21 units tall),
    # so each svg is sized to render the same ~11.7px tall content.
    {
      "ICON_LAYOUT_AUTO" => "18.5",
      "ICON_EXPAND_ALL" => "15",
      "ICON_TREE" => "17.6",
      "ICON_FIND" => "15",
      "ICON_REFRESH" => "15.6"
    }.each do |icon, size|
      svg = view[/const #{icon} = '<svg[^']*'/]
      expect(svg).to include(%(width="#{size}" height="#{size}"))
    end
  end

  it "opens the jump-to-file finder from a magnifier button" do
    expect(view).to include("findBtn.innerHTML = ICON_FIND")
    expect(view).to include("findBtn.addEventListener(\"click\", () => openFinder(findBtn))")

    finder = view[/function openFinder\(anchor\) \{.*?\n  \}/m]
    expect(finder).to include("setTimeout(() => input.focus(), 0)")
    expect(finder).to include("const changed = state.files.map((f) => f.path)")
  end

  it "searches only the files the panel is already showing" do
    finder = view[/function openFinder\(anchor\) \{.*?\n  \}/m]
    expect(finder).not_to include('api(state.sessionId, "paths")')
    expect(finder).to include("matchPaths(input.value, changed)")
  end

  it "keeps the finder inside the viewport" do
    expect(view).to include("function placeFinder(panel, anchor)")
    expect(view).to include("Math.min(r.left, window.innerWidth - width - 8)")
    expect(view).to include("Math.max(8, window.innerHeight - m.height - 8)")
  end

  it "releases the outside-click listener so a later finder still opens" do
    expect(view).to include("document.removeEventListener(\"click\", findOutside)")
    expect(view).to include("findOutside = closeFinder")
    expect(view).not_to include("document.addEventListener(\"click\", closeFinder, { once: true })")
  end

  it "scrolls the diff stream to the picked file" do
    pick = view[/function openChosenFile\(path\) \{.*?\n  \}/m]
    expect(pick).to include("focusFile(path)")
    expect(pick).not_to include("WorkspaceView")
  end

  it "ranks basename hits above matches spread over the directories" do
    score = view[/function scorePath\(query, path\) \{.*?\n  \}/m]
    expect(score).to include("fuzzyScore(query, name)")
    expect(score).to include("inName + 40")

    matcher = view[/function matchPaths\(query, files\) \{.*?\n  \}/m]
    expect(matcher).to include(".slice(0, 80)")
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
