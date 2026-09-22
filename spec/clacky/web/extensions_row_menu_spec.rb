# frozen_string_literal: true

RSpec.describe "Extensions row action menu UI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)   { File.read(File.join(web_dir, "features/extensions/view.js")) }
  let(:store)  { File.read(File.join(web_dir, "features/extensions/store.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }
  let(:i18n)   { File.read(File.join(web_dir, "i18n.js")) }
  let(:html)   { File.read(File.join(web_dir, "index.html")) }

  it "replaces the per-row enable switch with a shared … menu" do
    expect(view).to include('data-ext-more="${escapeHtml(id)}"')
    expect(view).to include("_toggleMenu(more, ext, id)")
    expect(view).not_to include("data-ext-row-toggle")
    expect(view).not_to include("ext-card-toggle")
    expect(view).not_to include("ext-row-done")
    expect(styles).not_to include(".ext-card-toggle")
  end

  it "offers manage and uninstall for marketplace rows" do
    expect(view).to include('return ext.removable === false ? ["manage"] : ["manage", "uninstall"]')
    expect(view).to include('manage:    "extensions.action.manage"')
    expect(view).to include('uninstall: "extensions.action.remove"')
    expect(view).to include("_openDetail(id, ext && ext.origin)")
    expect(view).to include("_confirmUninstall(id)")
  end

  it "offers the + affordance for official extensions that are switched off" do
    expect(view).to include('if (ext.layer === "builtin" && ext.disabled === true)')
    expect(view).to include('data-ext-row-enable="${escapeHtml(id)}"')
    expect(view).to include("Extensions.setEnabled(enable.dataset.extRowEnable, true)")
  end

  it "keeps disable reachable from the menu once an official row is switched on" do
    expect(view).to include('if (ext.layer === "builtin") return ["disable"]')
    expect(view).to include("Extensions.setEnabled(id, false)")
  end

  it "keeps disabled extensions out of the installed tab" do
    expect(view).to include("const live = st.installed.filter((e) => e.disabled !== true);")
    expect(view).to include('I18n.t("extensions.group.official"), items: live.filter((e) => e.layer === "builtin")')
    expect(view).to include('I18n.t("extensions.group.user"),     items: live.filter((e) => e.layer !== "builtin")')
  end

  it "lists the official group above the brand catalog on the brand tab" do
    expect(view).to include('if (st.tab === "brand") {')
    expect(view).to include('I18n.t("extensions.group.official"), items: st.official')
    expect(view).to include('I18n.t("extensions.group.brand"),    items: st.catalog')
  end

  it "loads the builtin list alongside the brand catalog" do
    expect(store).to include("const [official, brand] = await Promise.all([")
    expect(store).to include("_fetchOfficial(),")
    expect(store).to include("_official = official;")
    expect(store).to include("_catalog  = brand.extensions || [];")
  end

  it "labels the brand tab as the all tab and drops the unused brand filter key" do
    expect(html).to include('data-filter="brand" id="tab-extensions-brand" data-i18n="extensions.filter.all"')
    expect(i18n.scan('"extensions.group.brand"').size).to eq(2)
    expect(i18n).not_to include('"extensions.filter.brand"')
  end

  it "uninstalls by the installed slug, not by the store's own row id" do
    expect(view).to include('data-ext-menu-slug="${escapeHtml(slug)}"')
    expect(view).to include('const slug = item.getAttribute("data-ext-menu-slug") || id;')
    expect(view).to include("_confirmUninstall(slug)")
  end

  it "surfaces an uninstall failure as a toast instead of a phantom refresh" do
    expect(view).to include('Modal.toast(I18n.t("extensions.removeFailed")')
    body = store[/async uninstall\(.+?\n    \},/m]
    expect(body).to include("return { ok: false, error: e.message };")
    expect(body).not_to match(/_detailError\s*=/)
  end

  it "dismisses the floating menu on outside click, Escape, resize and scroll" do
    expect(view).to include("_wireMenuDismiss()")
    expect(view).to include('if (e.key === "Escape") _closeMenu()')
    expect(view).to include('window.addEventListener("resize", _closeMenu)')
    expect(view).to include('window.addEventListener("scroll", _closeMenu, true)')
  end

  it "repaints rows without stranding an open menu" do
    expect(view).to include("_closeMenu();")
    expect(view).to include('if (_menuBtn && _menuBtn.getAttribute("data-ext-more") === String(id)) _closeMenu();')
  end

  it "themes uninstall as dangerous and floats the menu above the panel" do
    expect(styles).to match(/\.ext-row-menu-danger \{ color: var\(--color-error\); \}/)
    expect(styles).to match(/\.ext-row-menu \{.*?position: fixed;.*?z-index: 1200;/m)
    expect(styles).to include(".ext-row-menu[hidden] { display: none; }")
  end

  it "ships manage/more labels in both locales" do
    expect(i18n.scan('"extensions.action.manage"').size).to eq(2)
    expect(i18n.scan('"extensions.action.more"').size).to eq(2)
  end
end
