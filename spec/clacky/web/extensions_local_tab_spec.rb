# frozen_string_literal: true

RSpec.describe "Extensions personal-creation tab UI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)   { File.read(File.join(web_dir, "features/extensions/view.js")) }
  let(:store)  { File.read(File.join(web_dir, "features/extensions/store.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }
  let(:i18n)   { File.read(File.join(web_dir, "i18n.js")) }
  let(:html)   { File.read(File.join(web_dir, "index.html")) }

  it "shows the local tab next to the installed one" do
    expect(html).to include('data-filter="local"')
    expect(html).to include('data-i18n="extensions.filter.local"')
    expect(i18n).to include('"extensions.filter.local":     "My creations"')
    expect(i18n).to include('"extensions.filter.local":     "我的创作"')
  end

  it "feeds the tab from a dedicated local endpoint" do
    expect(store).to include('get local()      { return _local.filter((e) => _matches(e, _query)); }')
    expect(store).to include('if (_tab === "local")     return Extensions.loadLocal();')
    expect(store).to include('const res  = await fetch("/api/store/extensions/local");')
  end

  it "renders the tab as one list that keeps switched-off extensions visible" do
    expect(view).to include('if (st.tab === "local") {')
    expect(view).to include("return [{ title: null, items: st.local }];")
    expect(view).to include('`<span class="extension-disabled">${escapeHtml(I18n.t("extensions.disabled"))}</span>`')
    expect(styles).to include(".extension-unlisted,\n.extension-disabled {")
  end

  it "offers enable for a switched-off local extension and disable once it runs" do
    expect(view).to include('if (ext.disabled === true) {')
    expect(view).to include('if (ext.layer === "local")   return ["iterate", "disable", "delete"];')
  end

  it "offers iterating on a local extension through a development session" do
    expect(view).to include('else if (kind === "iterate")   _iterateLocal(ext, id);')
    expect(view).to include('const data = await Extensions.createNew(')
    expect(view).to include("Sessions.setPendingRunTask(data.session_id)")
    expect(store).to include('fetch("/api/ext/ext-studio/develop"')
    expect(i18n).to include('"extensions.action.iterate":         "迭代"')
    expect(i18n).to include('"extensions.action.iterate":         "Iterate"')
    expect(i18n).to include('"extensions.action.iterateSeed":     "迭代扩展 {{id}}"')
    expect(view).to include('I18n.t("extensions.action.iterateSeed", { id: extId })')
    expect(view).not_to include('.replace("{id}", extId)')
  end

  it "offers a create entry in the header that opens a development session" do
    expect(html).to include('<button id="btn-create-extension" class="btn-create-extension"')
    expect(html).to include('data-i18n="extensions.btn.create"')
    expect(html).to include('data-i18n-title="extensions.create.tooltip"')
    expect(i18n).to include('"extensions.btn.create":        "Create"')
    expect(i18n).to include('"extensions.btn.create":        "创建"')
    expect(i18n).to include('"extensions.create.tooltip":    "让 AI 创建一个新扩展"')
    expect(i18n).to include('"extensions.createFailed":           "无法启动创建会话"')
    expect(view).to include('const createBtn = $("btn-create-extension");')
    expect(view).to include('createBtn.addEventListener("click", () => _createExtension());')
    expect(view).to include('Extensions.createNew(I18n.t("extensions.newExt.seed"))')
    expect(styles).to include(".btn-create-skill,\n.btn-create-extension {")
  end

  it "lets the personal-creation tab delete a local extension, behind a confirmation" do
    expect(view).to include('else if (kind === "delete")    _confirmDeleteLocal(id, ext);')
    expect(view).to include("const ok = await Modal.confirm(")
    expect(view).to include('await Extensions.deleteLocal(id)')
    expect(store).to include('fetch("/api/store/extension/delete-local"')
    expect(i18n).to include('"extensions.action.deleteLocal":     "Delete"')
    expect(i18n).to include('"extensions.action.deleteLocal":     "删除"')
    expect(i18n).to include('"extensions.action.deleteLocalConfirm": "确定删除「{{name}}」？删除后无法恢复。"')
    expect(view).to include('I18n.t("extensions.action.deleteLocalConfirm", { name })')
    expect(view).to include('I18n.t("extensions.deleteLocalDone", { name })')
    expect(view).not_to include('.replace("{name}", name)')
    expect(i18n).not_to include("目录 {path}")
  end

  it "separates the destructive menu item from the harmless one above it" do
    expect(view).to include('kind === "uninstall" || kind === "delete"')
    expect(view).to include('<div class="ext-row-menu-divider"></div>')
    expect(styles).to include(".ext-row-menu-divider {")
  end

  it "draws the delete glyph exactly like the session overflow menu's trash" do
    icons = view[/const MENU_ICONS = \{(.*?)\n  \};/m, 1].to_s
    delete_icon = icons[/delete:\s*'(.*?)',/m, 1].to_s
    sessions = File.read(File.join(web_dir, "sessions.js"))
    trash = sessions[/const iconTrash = `(.*?)`;/m, 1].to_s

    expect(trash).to include("M3 6h18")
    expect(delete_icon).to include("M3 6h18")
    expect(delete_icon).to include('viewBox="0 0 24 24"')
    expect(delete_icon).to include('stroke-width="1.8"')
    expect(delete_icon).to include('<line x1="10" y1="11" x2="10" y2="17"/>')
    expect(delete_icon).to include('<line x1="14" y1="11" x2="14" y2="17"/>')
  end

  it "keeps local rows inert and hides the marketplace sort control" do
    expect(view).to include('if (ext.layer !== "local") row.classList.add("extension-row-clickable");')
    expect(view).to include('(tab === "installed" || tab === "local") ? "none" : ""')
  end

  it "explains an empty personal-creation tab without pointing at the creator studio" do
    expect(view).to include('ExtensionsStore.state.tab === "local" ? "extensions.emptyLocal" : "extensions.empty"')
    expect(i18n).to include('"extensions.emptyLocal":    "No extensions created here yet."')
    expect(i18n).to include('"extensions.emptyLocal":    "还没有自己开发的扩展。"')
    expect(i18n).not_to include("创作者中心新建")
  end
end
