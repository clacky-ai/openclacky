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
    expect(settings).to include("if (options.tab) _activateTab(options.tab);")
    expect(settings).to include("Promise.all([loadModels, loadMedia]).then(() => {")
    expect(settings).to include("document.getElementById(options.section)")
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
