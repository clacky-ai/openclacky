# frozen_string_literal: true

# The changes panel has two pills: the scope (上一轮 / 未提交 / … / 已提交 /
# 分支) and - only for "分支" - a `head → base` compare pill. "已提交" opens a
# commit list and shows the picked commit subject inside its pill; "分支" is a
# plain row whose base is picked from the compare pill.
RSpec.describe "Git panel review scope" do
  let(:view) do
    File.read(File.expand_path("../../../lib/clacky/default_extensions/git/panels/git/view.js", __dir__))
  end

  it "sends a base for the branch and committed scopes only" do
    query = view[/function scopeQuery\(\) \{.*?\n  \}/m]
    expect(query).to include('state.scope === "branch" && state.base')
    expect(query).to include('state.scope === "committed" && state.commit')
  end

  it "keeps the server-resolved commit baseline out of the user pick" do
    refresh = view[/state\.sessionId = sessionId;.*?renderStream\(\);/m]
    expect(refresh).to include('if (state.scope === "branch" && !state.base && data.base) state.base = data.base;')
    expect(refresh).not_to include("state.commit = data.base")
  end

  it "opens the commit list from 已提交 and keeps 分支 a plain row" do
    items = view[/function scopeMenuItems\(\) \{.*?\n  \}/m]
    expect(items).to include('{ scope: "committed", submenu: "commits" },')
    expect(items).to match(/^      \{ scope: "branch" \},$/)
    expect(view).not_to match(/scope: "branch", submenu/)
  end

  it "keeps the scope pill wording fixed and shows the commit subject instead" do
    label = view[/function scopeLabel\(\) \{.*?\n  \}/m]
    expect(label).not_to include("state.base")

    subject = view[/function scopeSubject\(\) \{.*?\n  \}/m]
    expect(subject).to include('state.scope !== "committed"')
    expect(subject).to include("c.hash === state.commit")
    expect(subject).to include('t("changes.scope.commitCount"')
  end

  it "loads the commit list even when the menu is never opened" do
    expect(view).to include("async function loadCommits() {")
    refresh = view[/renderStats\(data\);\n    renderTree\(\);\n    renderStream\(\);.*?\n  \}/m]
    expect(refresh).to include('state.scope === "committed" && !state.commits')
    expect(refresh).to include("loadCommits()")
  end

  it "renders the compare pill only for the branch scope" do
    pill = view[/function comparePill\(data\) \{.*?\n  \}/m]
    expect(pill).to include('if (state.scope !== "branch") return null;')
    expect(pill).to include('el("span", { class: "cg-compare-arrow" })')
    expect(pill).to include('openRefMenu(btn, "branches"')

    rule = view[/\.cg-compare \.cg-scope-head, \.cg-compare \.cg-scope-base \{[^}]*\}/]
    expect(rule).not_to be_nil
    expect(rule).to include("text-overflow: ellipsis")
  end

  it "remembers each scope's pick separately" do
    apply = view[/function applyScope\(scope, value\) \{.*?\n  \}/m]
    expect(apply).to include('if (scope === "branch") state.base = value || "";')
    expect(apply).to include('else if (scope === "committed") state.commit = value || "";')
  end

  it "reviews the commit the user picked instead of a range from it" do
    list = view[/function renderRefList\(listEl, kind, onPick\) \{.*?\n  \}/m]
    expect(list).not_to include("isHead")
    expect(list).to include("const checked = state.commit === item.hash;")
    expect(list).to include("onPick(item.hash);")
  end
end
