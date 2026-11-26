# frozen_string_literal: true

RSpec.describe "Brand activation banner" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)    { File.read(File.join(web_dir, "features/brand/view.js")) }
  let(:store)   { File.read(File.join(web_dir, "features/brand/store.js")) }
  let(:settings) { File.read(File.join(web_dir, "settings.js")) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }
  let(:styles)  { File.read(File.join(web_dir, "app.css")) }

  it "no longer renders a bar for unactivated brand installs" do
    branch = view[/if \(data\.needs_activation\) \{.*?\n    \}/m]
    expect(branch).not_to be_nil
    expect(branch).not_to include("banner")
    expect(view).not_to include("_showActivationBanner")
    expect(view).not_to include("_renderActivationBanner")
    expect(view).not_to include("brand-activation-banner")
  end

  it "keeps the activation-state side effects it used to run alongside the bar" do
    branch = view[/if \(data\.needs_activation\) \{.*?\n    \}/m]
    expect(branch).to include("Settings.applyAccentColor(data.theme_color")
    expect(branch).to include("_applyHeaderLogo()")
    expect(branch).to include("_scheduleDistributionRefreshPoll()")
  end

  it "leaves no dangling markup, styles, store call or copy" do
    expect(store).not_to include("fetchSkillsBanner")
    expect(settings).not_to include("brand-activation-banner")
    expect(styles).not_to include("brand-activation-banner")
    expect(i18n).not_to include("brand.banner.")
  end

  it "still lets the skills panel jump to the license input" do
    expect(view).to include("goToLicenseInput:   _goToLicenseInput")
    skills_view = File.read(File.join(web_dir, "features/skills/view.js"))
    expect(skills_view).to include("Brand.goToLicenseInput()")
  end
end
