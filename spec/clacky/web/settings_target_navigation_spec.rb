# frozen_string_literal: true

RSpec.describe "Targeted Settings navigation" do
  let(:web_dir)  { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:app)      { File.read(File.join(web_dir, "app.js")) }
  let(:settings) { File.read(File.join(web_dir, "settings.js")) }
  let(:sessions) { File.read(File.join(web_dir, "sessions.js")) }
  let(:sidebar)  { File.read(File.join(web_dir, "components/sidebar.js")) }

  it "opens the Models tab from model-picker actions" do
    expect(sessions).to include('Router.navigate("settings", { tab: "models" })')
    expect(sessions).to include(
      'Router.navigate("settings", { tab: "models", section: "media-section" })'
    )
  end

  it "lets Settings own tab activation and post-load section scrolling" do
    expect(app).to include("Settings.open(params);")
    expect(settings).to include("function open(options = {})")
    expect(settings).to include('let _activeTab = "models";')
    expect(settings).to include("const targetTab = options.tab || _activeTab;")
    expect(settings).to include('if (!_activateTab(targetTab) && targetTab !== "models") _activateTab("models");')
    expect(settings).to include("Promise.all([loadModels, loadMedia]).then(() => {")
    expect(settings).to include("document.getElementById(options.section)")
  end

  it "records only complete tabs and reuses activation for branded fallback" do
    activate_tab = settings[/function _activateTab\(targetTab\).*?\n  \}/m]
    about_visibility = settings[/function _applyAboutTabVisibility\(\).*?\n  \}/m]

    expect(activate_tab).to include("if (!tab || !panel) return false;")
    expect(activate_tab).to include("_activeTab = targetTab;")
    expect(about_visibility).to include('_activateTab("models");')
    expect(about_visibility).not_to include("fallbackPanel")
  end

  it "keeps ordinary Settings navigation untargeted" do
    expect(sidebar).to include('Router.navigate("settings");')
    expect(sidebar).not_to include('Router.navigate("settings", {')
  end

  it "does not rely on a timer to find the media section" do
    configure_media = sessions[/function _goConfigureMedia\(\).*?\n  \}/m]
    expect(configure_media).not_to be_nil
    expect(configure_media).not_to include("setTimeout")
    expect(configure_media).not_to include("scrollIntoView")
  end
end
