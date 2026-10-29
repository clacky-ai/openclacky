# frozen_string_literal: true

# The context bar used to be rebuilt from scratch on every store event. A
# project switch fires three of them (project, git loading, git loaded), and the
# branch chip only exists once git info is known — so the row was repainted two
# or three times and the model / init chips jogged sideways on every switch.
RSpec.describe "New-session context bar rendering" do
  let(:root) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view) { File.read(File.join(root, "features/new-session/view.js")) }
  let(:styles) { File.read(File.join(root, "app.css")) }
  let(:renderbar) { view[/function _renderContextBar\(\) \{.*?\n  \}\n/m] }

  it "builds the chips once and reuses them" do
    expect(renderbar).not_to be_nil
    expect(renderbar).to include("_ensureCtxChips(bar)")
    expect(renderbar).not_to include('bar.innerHTML = ""')
    expect(renderbar).to include('_setChipLabel(chips.')

    builder = view[/function _ensureCtxChips\(bar\) \{.*?\n  \}\n/m]
    expect(builder).not_to be_nil
    expect(builder).to include("if (_ctxChips && _ctxChips.name.parentElement === bar) return _ctxChips;")
    expect(builder).to include("CTX_CHIP_ORDER.forEach")
  end

  it "keeps a fixed chip order in the DOM" do
    expect(view).to include('const CTX_CHIP_ORDER = ["name", "project", "dir", "branch", "model", "init"];')
  end

  # While git info is in flight the branch chip must hold its slot; hiding it
  # there is exactly what shifted the chips that follow.
  it "keeps the branch chip in place while git info loads" do
    expect(renderbar).to include("chips.branch.hidden = !showBranch || (gitKnown && !git.repo);")
    expect(renderbar).to include("正在读取分支…")
  end

  it "hides chips without the layout engine leaving a gap" do
    expect(styles).to include(".ns-ctx-chip[hidden] {")
    rule = styles[/\.ns-ctx-chip\[hidden\] \{[^}]*\}/]
    expect(rule).to include("display: none")
  end

  # Vendor badges are nodes and carry their own colors, so they are appended
  # rather than injected as markup, and skip the 0.7 icon opacity.
  it "appends the model vendor badge as a node" do
    expect(view).to include("icon instanceof Node")
    expect(styles[/\.ns-ctx-chip-icon--badge \{[^}]*\}/]).to include("opacity: 1")
  end
end
