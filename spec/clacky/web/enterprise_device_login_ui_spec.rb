# frozen_string_literal: true

RSpec.describe "Enterprise device login WebUI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:index) { File.read(File.join(web_dir, "index.html")) }
  let(:onboard) { File.read(File.join(web_dir, "components/onboard.js")) }
  let(:i18n) { File.read(File.join(web_dir, "i18n.js")) }

  it "renders enterprise login as a compact footer link with a staged platform URL form" do
    expect(index).to include('id="setup-btn-enterprise-login"')
    expect(index).to include('class="setup-enterprise-link"')
    expect(index).not_to include('id="setup-enterprise-card"')
    expect(index.index('id="setup-btn-enterprise-login"')).to be >
      index.index('id="setup-manual-section"')
    expect(index).to include('id="setup-enterprise-form"')
    expect(index).to include('id="setup-enterprise-source"')
    expect(index).to include('value="https://www.openclacky.com"')
    expect(index).to include('id="setup-enterprise-cancel"')
    expect(i18n).to include('"onboard.enterprise.btn":             "Enterprise user? Sign in →"')
    expect(i18n).to include('"onboard.enterprise.source.label":')
  end

  it "sends the staged source to both device authorization requests" do
    expect(onboard).to match(
      /async function _startDeviceLogin\(platformSource = null\).*?platform_source: platformSource/m
    )
    expect(onboard).to match(
      /_pollDevice\(\s*data\.device_code,\s*\(data\.interval \|\| 5\) \* 1000,.*?platformSource/m
    )
    expect(onboard).to match(
      /async function _pollDevice\(deviceCode, intervalMs, platformSource\).*?platform_source: platformSource/m
    )
  end

  it "does not save the platform source before remote approval" do
    enterprise_flow = onboard[
      /async function _startEnterpriseDeviceLogin.*?(?=\n  async function _startDeviceLogin)/m
    ]

    expect(enterprise_flow).not_to be_nil
    expect(enterprise_flow).not_to include("/api/config/settings")
    expect(enterprise_flow).not_to include("_savePlatformSource")
  end

  it "keeps enterprise login visible in branded onboarding" do
    setup_step = onboard[/function _showSetupStep.*?(?=\n  \/\/ Step 2)/m]

    expect(setup_step).to include('$("setup-device-block").style.display')
    expect(setup_step).to include('$("setup-btn-enterprise-login").style.display')
    expect(setup_step).not_to match(
      /if \(_branded\).*?\$\("setup-device-block"\)\.style\.display\s*=\s*"none"/m
    )
  end

  it "uses the enterprise button id for every visibility transition" do
    expect(onboard).not_to include('$("setup-enterprise-link")')
    expect(onboard.scan('$("setup-btn-enterprise-login")').length).to be >= 4
  end

  it "shows the concrete model returned by the enterprise" do
    expect(onboard).to include("_showDeviceSuccess(data.default_model")
    expect(index).to include('id="setup-device-success-model"')
    expect(i18n).not_to include("Auto ·")
  end
end
