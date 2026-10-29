# frozen_string_literal: true

# The branch list is a flex column: without flex-shrink: 0 the rows collapse to
# a few pixels as soon as the list overflows instead of scrolling.
RSpec.describe "New-session branch popover layout" do
  let(:root) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view) { File.read(File.join(root, "features/new-session/view.js")) }
  let(:styles) { File.read(File.join(root, "app.css")) }

  it "keeps branch rows at full height so long lists scroll" do
    rule = styles[/\.ns-branch-list > \* \{[^}]*\}/]
    expect(rule).not_to be_nil
    expect(rule).to include("flex-shrink: 0")
  end

  it "resets the scroll position when the filter changes" do
    expect(view).to include("list.innerHTML = \"\";\n        list.scrollTop = 0;")
  end

  it "keeps the popover inside a narrow viewport" do
    expect(view).to include("if (popRect.right > window.innerWidth - 8) {")
    expect(view).to include("Math.max(8, window.innerWidth - popRect.width - 8)")
  end

  it "insets the dividers instead of running them into the frame" do
    rule = styles[/\.ns-branch-foot::before \{[^}]*\}/]
    expect(rule).not_to be_nil
    expect(rule).to include("left: 0.5rem", "right: 0.5rem")

    %w[search foot].each do |zone|
      block = styles[/\.ns-branch-#{zone} \{[^}]*\}/]
      expect(block).not_to be_nil
      expect(block).not_to match(/border-(top|bottom)/)
    end
  end

  # Raw git stderr used to be printed in a status row pinned under the list,
  # which pushed the footer around and left English text on a Chinese UI.
  it "reports checkout failures as a toast instead of a footer row" do
    expect(view).not_to include("ns-branch-status")
    expect(styles).not_to include("ns-branch-status")
    expect(view).to include('Clacky.Modal.toast(msg, "error")')
    expect(view).to include("_branchErrorText(e.message, zh, branch)")
    expect(view).to include("本地有未提交的修改，切换分支会被覆盖")
    expect(view).to include("分支 ${found ? found[1] : branch || \"\"} 已存在。")
  end

  it "leaves the search row without a divider under the popover edge" do
    expect(styles).not_to include(".ns-branch-search::after")
  end
end
