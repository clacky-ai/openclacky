# frozen_string_literal: true

RSpec.describe "Row action tooltips" do
  let(:web_dir)    { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:extensions) { File.read(File.join(web_dir, "features/extensions/view.js")) }
  let(:channels)   { File.read(File.join(web_dir, "features/channels/view.js")) }
  let(:i18n)       { File.read(File.join(web_dir, "i18n.js")) }

  it "draws the extension install and enable buttons with the shared tooltip" do
    expect(extensions).to include(%(data-ext-row-install="${escapeHtml(id)}" data-tooltip="${escapeHtml(I18n.t("extensions.action.install"))}"))
    expect(extensions).to include(%(data-ext-row-enable="${escapeHtml(id)}" data-tooltip="${escapeHtml(I18n.t("extensions.action.enable"))}"))
    expect(extensions).not_to include(%(data-ext-row-install="${escapeHtml(id)}" title=))
    expect(extensions).not_to include(%(data-ext-row-enable="${escapeHtml(id)}" title=))
  end

  it "draws the channel setup buttons with the shared tooltip" do
    expect(channels).to include(%(data-channel-setup="${_esc(platform)}"))
    expect(channels).to include(%(data-tooltip="${_esc(I18n.t("channels.btn.setup"))}" data-i18n-tooltip="channels.btn.setup"))
    expect(channels).to include(%(data-tooltip="${_esc(I18n.t("channels.customDev.btn"))}" data-i18n-tooltip="channels.customDev.btn"))
    expect(channels).not_to include(%(title="${_esc(I18n.t("channels.btn.setup"))}"))
    expect(channels).not_to include(%(title="${_esc(I18n.t("channels.customDev.btn"))}"))
  end

  it "keeps every key the templates look up in both locales" do
    %w[
      extensions.action.install
      extensions.action.enable
      channels.btn.setup
      channels.customDev.btn
    ].each do |key|
      expect(i18n.scan(%("#{key}":)).length).to eq(2), "#{key} is missing from a locale"
    end
  end
end
