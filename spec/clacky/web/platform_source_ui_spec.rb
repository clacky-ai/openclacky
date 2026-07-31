# frozen_string_literal: true

RSpec.describe "Platform source WebUI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:index) { File.read(File.join(web_dir, "index.html")) }
  let(:settings) { File.read(File.join(web_dir, "settings.js")) }
  let(:i18n) { File.read(File.join(web_dir, "i18n.js")) }
  let(:brand_store) { File.read(File.join(web_dir, "features/brand/store.js")) }
  let(:brand_view) { File.read(File.join(web_dir, "features/brand/view.js")) }
  let(:save_platform_source) do
    settings[
      /async function _savePlatformSource.*?(?=\n  async function _waitForPlatformSourceRestart)/m
    ]
  end
  let(:wait_for_platform_source_restart) do
    settings[
      /async function _waitForPlatformSourceRestart.*?(?=\n  \/\/ Load and render)/m
    ]
  end

  it "renders Save and Restore controls for the platform source" do
    expect(index).to include('id="btn-save-clacky-license-server"')
    expect(index).to include('id="btn-restore-clacky-license-server"')
    expect(i18n).to include('"settings.brand.source.save":        "Save"')
    expect(i18n).to include('"settings.brand.source.restore":     "Restore"')
    expect(i18n).to include('"settings.brand.source.save":        "保存"')
    expect(i18n).to include('"settings.brand.source.restore":     "还原"')
  end

  it "restores through the existing save flow using the official source" do
    expect(settings).to include(
      'const OFFICIAL_PLATFORM_SOURCE = "https://www.openclacky.com";'
    )
    expect(settings).to include("_savePlatformSource(OFFICIAL_PLATFORM_SOURCE)")
  end

  it "retries brand recovery after saving an unchanged source" do
    expect(save_platform_source).to include("Brand.refresh()")
  end

  it "waits for a WebSocket disconnect and reconnect before refreshing the source" do
    expect(wait_for_platform_source_restart).to include(
      "let disconnected = !WS.ready;"
    )
    expect(wait_for_platform_source_restart).to match(
      /if \(!WS\.ready\) disconnected = true;.*?if \(disconnected && WS\.ready\) return true;/m
    )
  end

  it "refreshes branding in place after a source restart without reloading the page" do
    expect(save_platform_source).not_to include("window.location.reload()")
    expect(save_platform_source).to match(
      /if \(!reconnected\).*?throw new Error.*?await Brand\.refresh\(\)/m
    )
  end

  it "re-emits refreshed brand status and polls while source branding is pending" do
    expect(brand_store).to match(
      /async refresh\(\).*?_emit\("brand:status", data\)/m
    )
    expect(brand_view).to match(
      /!data\.branded.*?distribution_refresh_pending.*?_scheduleDistributionRefreshPoll\(\)/m
    )
  end

  it "keeps the current brand while refresh is pending and restores defaults once settled" do
    expect(brand_view).to match(
      /!data\.branded.*?distribution_refresh_pending.*?_scheduleDistributionRefreshPoll\(\).*?return;.*?_applyBrandName\("OpenClacky"\).*?Brand\.clearBrandCache\(\).*?_applyHeaderLogo\(\)/m
    )
  end

  it "restores the default favicon with the default brand" do
    expect(brand_view).to match(
      /function _applyDefaultLogo.*?_applyFavicon\("\/favicon\.svg"\)/m
    )
  end

  it "refreshes the settings brand status when a pending refresh settles" do
    expect(brand_view).to match(
      /if \(refreshSettled.*?Settings\.loadBrand\(\)/m
    )
  end

  it "resets the activation prompt when the settled source has no brand" do
    expect(settings).to match(
      /desc\.textContent = data\.product_name\s+\?\s+I18n\.t\("settings\.brand\.descNamed".*?:\s+I18n\.t\("settings\.brand\.desc"\)/m
    )
  end
end
