# frozen_string_literal: true

RSpec.describe "Settings browser toggle" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:settings) { File.read(File.join(web_dir, "settings.js")) }
  let(:styles)   { File.read(File.join(web_dir, "app.css")) }
  let(:i18n)     { File.read(File.join(web_dir, "i18n.js")) }
  let(:load_fn)  { settings[/async function _loadBrowserStatus\(\)[\s\S]*?\n  \}/] }
  let(:toggle_fn) { settings[/async function _toggleBrowser\(\)[\s\S]*?\n  \}/] }

  it "hides the switch until browser.yml exists" do
    expect(load_fn).to include("data.configured === false")
    expect(load_fn).not_to include("data.enabled === undefined")
  end

  it "labels the switch with a hover hint for the action it performs" do
    expect(load_fn).to include("settings.browser.toggle.turnOff")
    expect(load_fn).to include("settings.browser.toggle.turnOn")
    expect(load_fn).to match(/toggleWrap\.setAttribute\("data-tooltip", toggleHint\)/)
    expect(load_fn).to match(/toggleInput\.setAttribute\("aria-label", toggleHint\)/)
  end

  it "reports a failed toggle instead of silently flipping back" do
    expect(toggle_fn).to include("Modal.toast(")
    expect(toggle_fn).to include("settings.browser.toggle.failed")
  end

  it "tells the user to configure the browser when browser.yml is missing" do
    expect(toggle_fn).to include('e.code === "not_configured"')
    expect(toggle_fn).to include("settings.browser.toggle.notConfigured")
  end

  it "drops the status emoji that rendered as a stray glyph" do
    expect(i18n).to include('"settings.browser.disabled":         "Browser disabled"')
    expect(i18n).to include('"settings.browser.disabled":         "浏览器已禁用"')
    expect(i18n).not_to include("⏸")
  end

  it "ships the toggle hint copy in both locales" do
    %w[turnOn turnOff failed notConfigured].each do |key|
      expect(i18n.scan(/settings\.browser\.toggle\.#{key}/).size).to eq(2)
    end
  end

  it "keeps the switch visible on a light background" do
    track = styles[/\.toggle-slider \{[^}]*\}/]
    expect(track).to include("color-mix(in srgb, var(--color-text-tertiary)")
    expect(styles).to match(/\.toggle-switch:hover \.toggle-slider \{[^}]*box-shadow/)
    expect(styles).to match(/\.toggle-switch input:disabled \+ \.toggle-slider \{[^}]*opacity/)
  end
end
