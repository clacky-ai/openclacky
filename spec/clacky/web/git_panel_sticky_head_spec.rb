# frozen_string_literal: true

# A sticky box can only travel inside its containing block. The file header sits
# in a block-level section that is exactly one pane wide, so scrolling a long
# line sideways used to drag the header (and its path) out of view. The fix
# stretches the section to the full scroll width - the same trick .cg-line and
# .cg-fold already use - and keeps the header one pane wide.
RSpec.describe "Git panel sticky file header" do
  let(:view) do
    File.read(File.expand_path("../../../lib/clacky/default_extensions/git/panels/git/view.js", __dir__))
  end

  it "stretches the file section to the scroll width so the header can stick" do
    rule = view[/\.changes-root:not\(\.is-wrap\) \.cg-file \{ min-width: var\(--cg-span-w, 0px\); \}/]
    expect(rule).not_to be_nil
  end

  it "pins the header with a pane-wide, border-box width" do
    rule = view[/\.cg-file-head \{[^}]*\}/]
    expect(rule).to include("position: sticky")
    expect(rule).to include("top: 0")
    expect(rule).to include("left: 0")
    expect(rule).to include("box-sizing: border-box")
    expect(rule).to include("width: var(--cg-pane-w, auto)")
  end

  it "records the pane width next to the scroll width in syncSpan" do
    span = view[/function syncSpan\(\) \{.*?\n  \}/m]
    expect(span).to include('stream.style.setProperty("--cg-pane-w", stream.clientWidth + "px")')
    expect(span).to include('stream.style.setProperty("--cg-span-w", stream.scrollWidth + "px")')
  end

  it "refreshes the pane width on sidebar drag and window resize" do
    observer = view[/state\.ro = new ResizeObserver\(\(\) => \{.*?\n      \}\);/m]
    expect(observer).not_to be_nil
    expect(observer).to include("scheduleSpan()")
    expect(observer).to include("reflowBodies()")
  end
end
