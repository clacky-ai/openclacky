# frozen_string_literal: true

RSpec.describe "Brand skills unreachable-license-server notice" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)    { File.read(File.join(web_dir, "features/skills/view.js")) }
  let(:styles)  { File.read(File.join(web_dir, "app.css")) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }
  let(:markup)  { File.read(File.join(web_dir, "index.html")) }

  it "uses the warning variant instead of the error variant" do
    expect(markup).to include('id="brand-skills-warning" class="inline-notice inline-notice--warning"')
    expect(markup).not_to match(/id="brand-skills-warning"[^>]*inline-notice--error/)
  end

  it "styles the warning variant with warning tokens and gives the action a hover state" do
    warning_rule = styles[/\.inline-notice--warning \{(.*?)\}/m, 1]
    expect(warning_rule).to include("var(--color-warning-bg)")
    expect(warning_rule).to include("var(--color-warning-border)")
    expect(warning_rule).to include("var(--color-warning-text)")
    expect(styles).to include(".inline-notice-action:hover")
    expect(styles).to include(".inline-notice-action:disabled")
  end

  it "renders a retry action that reloads the brand skill list" do
    render = view[/function _renderBrandWarning\(\) \{(.*?)^  \}/m, 1]
    expect(render).to include('"inline-notice-action"')
    expect(render).to include("Skills.loadBrandSkills()")
    expect(render).to include('"skills.brand.warning.retry"')
  end

  it "splits the notice copy between a degraded list and an empty list" do
    expect(i18n).to include('"skills.brand.warning.remote_unavailable": "暂时无法连接授权服务器，列表可能不是最新。"')
    expect(i18n).to include('"skills.brand.warning.remote_unavailable.empty": "暂时无法连接授权服务器，请检查网络后重试。"')
    expect(i18n).to include('"skills.brand.warning.retry": "重试"')
    expect(i18n).not_to include("仅显示本地已安装的技能")
    expect(view).to include('(_brandWarning.empty ? ".empty" : "")')
  end

  it "does not show the empty-state line while the notice explains the empty list" do
    render = view[/function _renderBrandSkills\(\) \{(.*?)^  \}/m, 1]
    expect(render).to include("container.innerHTML = _brandWarning")
    expect(render).to include("I18n.t(\"skills.brand.empty\")")
  end

  it "picks the empty-list variant when the tab has nothing to show" do
    handler = view[/Skills\.on\("brandSkills:changed", \(p\) => \{(.*?)^    \}\);/m, 1]
    expect(handler).to include("const noContent = brandSkills.length === 0")
    expect(handler).to include("_applyBrandWarning(p.warning, p.warningCode, noContent)")
  end

  it "re-renders the notice copy on language change" do
    lang_change = view[/document\.addEventListener\("langchange", \(\) => \{(.*?)^    \}\);/m, 1]
    expect(lang_change).to include("_renderBrandWarning()")
  end
end
