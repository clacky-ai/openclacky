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

  it "groups the tool buttons into one pill, refresh still at its far right" do
    tools = view[/const tools = el\("div", \{ class: "cg-tools" \},.*?\);/m]
    expect(tools).not_to be_nil
    expect(tools).to include("layoutBtn, wrapBtn, expandBtn, treeBtn, findBtn, refreshBtn")

    bar = view[/const bar = el\("div", \{ class: "cg-bar" \},.*?\);/m]
    expect(bar).to include("stats")
    expect(bar).to include("cg-bar-spacer")
    expect(bar).to include("tools")
  end

  it "draws the tool group as a bordered pill inside the bar" do
    pill = view[/\.cg-tools \{[^}]*\}/]
    expect(pill).to include("border-radius: var(--radius-pill)")
    expect(pill).to include("border: 1px solid var(--color-border-primary)")
  end

  it "leaves long diff lines unwrapped until the wrap toggle is on" do
    expect(view).to include('wrap: false,')

    # Unwrapped rows stretch to the widest line so tints span the whole row.
    box = view[/\.changes-root:not\(\.is-wrap\) \.cg-lines:not\(\.is-cols\) \{[^}]*\}/]
    expect(box).to include("width: max-content")
    row = view[/\.changes-root:not\(\.is-wrap\) \.cg-lines:not\(\.is-cols\) > \.cg-line \{[^}]*\}/]
    expect(row).to include("width: 100%")
    expect(view).to include(".changes-root.is-wrap .cg-line { white-space: pre-wrap")

    apply = view[/function applyWrapButton\(\) \{.*?\n  \}/m]
    expect(apply).to include('btn.classList.toggle("is-on", state.wrap)')
    expect(apply).to include('t("changes.wrap"')

    setter = view[/function setWrap\(on\) \{.*?\n  \}/m]
    expect(setter).to include('classList.toggle("is-wrap", state.wrap)')
    expect(setter).to include("localStorage.setItem(WRAP_KEY")

    boot = view[/state\.els = \{ root: root.*?applyWrapButton\(\);/m]
    expect(boot).to include('localStorage.getItem(WRAP_KEY) === "1"')
  end

  it "gives each unwrapped split pane its own sideways scroll" do
    expect(view).to include("const panes = split && !state.wrap;")
    expect(view).to include('lines.classList.toggle("is-cols", panes)')

    col = view[/\.cg-col \{[^}]*\}/]
    expect(col).to include("flex: 1 1 0")
    expect(col).to include("overflow-x: auto")
    expect(view[/\.cg-col\.old \{[^}]*\}/]).to include("border-right")

    side = view[/function diffSide\(line, side, lang\) \{.*?\n  \}/m]
    expect(side).to include("cg-line ${side}")
    expect(side).to include("blank")

    sync = view[/function syncPaneScroll\(cols\) \{.*?\n  \}/m]
    expect(sync).to include("to.scrollLeft = from.scrollLeft")

    # Wrapping swaps the panes back to paired rows, so the switch re-renders.
    expect(view[/function setWrap\(on\) \{.*?\n  \}/m]).to include("reflowBodies()")
  end

  it "keeps gutter cells full height so tints cover the whole row" do
    # An empty gutter span has no content, so it collapses to 0px unless it is
    # stretched, leaving the row tint ragged at the gutter.
    expect(view).to include(".cg-ln { flex: none; align-self: stretch;")

    unified = view[/\.changes-root:not\(\.is-wrap\) \.cg-lines:not\(\.is-cols\) > \.cg-line > \.cg-ln \{[^}]*\}/]
    expect(unified).to include("position: sticky")
    expect(unified).to include("background-color: var(--color-bg-primary)")
    expect(unified).to include("linear-gradient(var(--cg-row-tint")

    expect(view[/\.cg-line\.add \{[^}]*\}/]).to include("--cg-row-tint:")
    expect(view[/\.cg-line\.del \{[^}]*\}/]).to include("--cg-row-tint:")
    # The row's own wash rides on a gradient as well: the unwrapped and pane
    # rules set an opaque background-color with more specificity, so a plain
    # `background` on .add/.del would leave the code area untinted.
    expect(view[/\.cg-line \{[^}]*\}/]).to include("linear-gradient(var(--cg-row-tint")
  end

  it "prints a single line number per row in the single-column stream" do
    # Old and new numbers drift apart after an insertion, so two gutters read as
    # a duplicated column; the stream shows the number the file actually has.
    rows = view[/for \(let i = 0; i < hunk\.lines\.length.*?frag\.appendChild\(row\);/m]
    expect(rows).not_to be_nil
    expect(rows.scan('class: "cg-ln"').size).to eq(1)
    expect(rows).to include("line.newNo == null ? line.oldNo : line.newNo")
  end

  it "pins only the arrow chip while the label scrolls with the code" do
    # Two separate chips: the arrow block stays in the gutter column, the label
    # rides along with the lines so the strip reads as part of the diff.
    fold = view[/\.cg-fold \{[^}]*\}/]
    expect(fold).not_to include("position: sticky")
    expect(fold).not_to include("background:")

    gutter = view[/\.cg-fold \.cg-fold-gutter \{[^}]*\}/]
    expect(gutter).to include("position: sticky")
    expect(gutter).to include("left: 0")
    expect(gutter).to include("background-color: var(--color-bg-primary)")

    label = view[/\.cg-fold \.cg-fold-label \{[^}]*\}/]
    expect(label).not_to include("position: sticky")
    expect(label).to include("background: rgba(127, 127, 127")

    expect(view).not_to include("--cg-view-w")
  end

  it "spans the scroll content so sticky parts keep pinning past the pane edge" do
    # Sticky is clipped to its containing block: a strip or row as wide as the
    # visible pane would stop pinning once the diff scrolls beyond it — the
    # arrow slides away and short rows lose their line numbers.
    fold = view[/\.changes-root:not\(\.is-wrap\) \.cg-fold \{[^}]*\}/]
    expect(fold).to include("min-width: var(--cg-span-w")

    row = view[/\.changes-root:not\(\.is-wrap\) \.cg-col > \.cg-line \{[^}]*\}/]
    expect(row).to include("min-width: var(--cg-span-w")

    expect(view).to include("function syncSpan")
    expect(view).to include('setProperty("--cg-span-w", stream.scrollWidth')
    expect(view).to include('setProperty("--cg-span-w", cols[i].scrollWidth')
  end

  it "keeps the toolbar icons optically the same size" do
    # The artwork bounds differ inside the 24 grid (roughly 15-21 units tall),
    # so each svg is sized to render the same ~11.7px tall content.
    {
      "ICON_LAYOUT_AUTO" => "18.5",
      "ICON_EXPAND_ALL" => "15",
      "ICON_TREE" => "17.6",
      "ICON_FIND" => "15",
      "ICON_WRAP" => "15.5",
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
