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

  it "re-emits refreshed brand status and polls while source branding is pending" do
    expect(brand_store).to match(
      /async refresh\(\).*?_emit\("brand:status", data\)/m
    )
    expect(brand_view).to match(
      /!data\.branded.*?distribution_refresh_pending.*?_scheduleDistributionRefreshPoll\(\)/m
    )
  end
end
