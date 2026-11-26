# frozen_string_literal: true

RSpec.describe "Brand warning bar" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)    { File.read(File.join(web_dir, "features/brand/view.js")) }
  let(:styles)  { File.read(File.join(web_dir, "app.css")) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }
  let(:settings) { File.read(File.join(web_dir, "settings.js")) }

  it "no longer renders a top warning bar for license status" do
    expect(view).not_to include("brand-warning")
    expect(view).not_to match(/function _showWarning/)
    expect(styles).not_to include(".brand-warning-bar")
    expect(i18n).not_to include("brand.warning.renewBtn")
    expect(i18n).not_to include("brand.skip.warning")
  end

  it "still applies the branded header on a status frame that carries a warning" do
    on_status = view[/function _onStatus\(data\) \{\n(.*?)^  \}/m, 1]
    expect(on_status).to include("_applyHeaderLogo()")
    expect(on_status).to include("_applyOwnerBadge()")
    expect(on_status).not_to include("warning")
  end

  it "still boots the UI when activation is skipped" do
    skip = view[/function _skipActivation\(\) \{\n(.*?)^  \}/m, 1]
    expect(skip).to include("_bootUI()")
  end

  it "keeps the license status visible in Settings" do
    expect(settings).to include('wt === "expired"')
    expect(settings).to include('wt === "unreachable"')
  end
end
