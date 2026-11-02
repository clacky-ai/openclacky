# frozen_string_literal: true

require "open3"

RSpec.describe "Web open-with submenu" do
  let(:root) { File.expand_path("../../..", __dir__) }
  let(:utils) { File.read(File.join(root, "lib/clacky/web/utils.js")) }
  let(:git_view) { File.read(File.join(root, "lib/clacky/default_extensions/git/panels/git/view.js")) }
  let(:app_css) { File.read(File.join(root, "lib/clacky/web/app.css")) }
  let(:i18n) { File.read(File.join(root, "lib/clacky/web/i18n.js")) }

  it "unfolds the app list on hover and opens the pick through the backend" do
    script = File.expand_path("../../support/open_with_menu_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end

  it "keeps one shared component instead of a per-panel copy" do
    expect(utils).to include("const OpenWith = (() => {")
    expect(utils).to include('fetchOpenWithApps(target)')
    expect(utils).to include("openWithApp(absEntry(entry), appPath)")
    # The submenu flips to the left of the menu when the right edge is crowded.
    expect(utils).to include("left = Math.max(8, hostRect.left - subRect.width);")
  end

  it "offers the submenu from the Git panel file tree" do
    expect(git_view).to include(
      '["openwith", ICON_OPEN_WITH, t("workspace.openWithMenu", "打开方式"), null]'
    )
    expect(git_view).to include("OpenWith.mount(row, menuEntry(path), { menu: menu })")

    build_menu = git_view[/  function buildMenu\(items\) \{.*?\n  \}/m]
    expect(build_menu).to include("if (run) {"), "rows without an action must not close the menu"
  end

  it "offers the submenu from the Files tree but not for folders" do
    workspace_view = File.read(File.join(root, "lib/clacky/web/features/workspace/view.js"))
    expect(workspace_view).to include(
      'const openWithItem = entry.type === "file" ? `'
    )
    expect(workspace_view).to include("OpenWith.mount(row, entry, { menu: menu })")
  end

  it "orders both file menus the same way" do
    workspace_view = File.read(File.join(root, "lib/clacky/web/features/workspace/view.js"))
    order = %w[addtochat openwith reveal copypath copyrelpath download]
    labels = { "addToChatItem" => "addtochat", "openWithItem" => "openwith", "downloadItem" => "download" }

    git_menu = git_view[/function openFileMenu\(ev, path, isDir\) \{.*?\n  \}/m]
    files_menu = workspace_view[/menu\.innerHTML = `.*?`;/m]

    expect(git_menu).not_to be_nil
    expect(files_menu).not_to be_nil

    git_actions = git_menu.scan(/items\.push\(\["(\w+)"/).flatten
    files_actions = files_menu.scan(/\$\{(\w+Item)\}|data-action="(\w+)"/)
                             .map { |var, inline| labels[var] || inline }

    expect(git_actions).to eq(order)
    expect(files_actions).to eq(order)
  end

  it "renders the viewer's open-with dropdown from the same app rows" do
    workspace_view = File.read(File.join(root, "lib/clacky/web/features/workspace/view.js"))
    expect(workspace_view).to include('{ base: "session-actions-menu" }')
    expect(workspace_view).not_to include("fetchOpenWithApps(entry)"),
      "the viewer must not rebuild the app list it gets from OpenWith"
    expect(utils).to include("return { mount: mount, appRows: appRows, close: close };")
  end

  it "ships both languages for the empty-apps hint" do
    expect(i18n.scan('"workspace.openWithEmpty"').size).to eq(2)
  end

  it "gives the submenu rows real app icons and a default-app weight" do
    expect(app_css).to include(".menu-app-icon { width: 1.25rem; height: 1.25rem; }")
    expect(app_css).to include(".menu-app-icon img {")
    expect(app_css).to include(".session-actions-submenu-item.is-default,")
    expect(app_css).to include(".wv-open-menu .session-actions-menu-item.is-default {")
  end
end
