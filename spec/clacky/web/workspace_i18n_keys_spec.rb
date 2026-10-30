# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Workspace panel i18n keys" do
  let(:view_path) { File.expand_path("../../../lib/clacky/web/features/workspace/view.js", __dir__) }
  let(:i18n_path) { File.expand_path("../../../lib/clacky/web/i18n.js", __dir__) }

  let(:view) { File.read(view_path) }
  let(:i18n) { File.read(i18n_path) }

  let(:en_keys) { i18n[/\n    en: \{\n(.*?)\n    \}/m, 1].scan(/^\s+"([\w.]+)":/).flatten }
  let(:zh_keys) { i18n[/\n    zh: \{\n(.*?)\n    \}/m, 1].scan(/^\s+"([\w.]+)":/).flatten }
  let(:used_keys) { view.scan(/\bt\("([\w.]+)"/).flatten.uniq }

  it "resolves every t() call to a real translation" do
    missing = used_keys.reject { |key| en_keys.include?(key) && zh_keys.include?(key) }
    expect(missing).to be_empty
  end

  it "labels the preview toggle" do
    expect(en_keys).to include("workspace.preview")
    expect(zh_keys).to include("workspace.preview")
  end
end
