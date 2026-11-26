# frozen_string_literal: true

RSpec.describe "Extensions brand tab: license status warning" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:store)   { File.read(File.join(web_dir, "features/extensions/store.js")) }
  let(:load_brand) { store[/async loadBrand\(\) \{\n(.*?)^    \},/m, 1] }

  # The brand catalog reports license state (expired / revoked …) through
  # `warning`. That status belongs in Settings → Brand & License, so the tab
  # must not turn it into an inline notice.
  it "does not surface the brand catalog warning as an in-page notice" do
    expect(load_brand).not_to be_nil
    expect(load_brand).not_to include("brand.warning")
  end

  it "still surfaces the public market warning" do
    expect(store).to include("_error    = market.warning || null;")
  end

  it "still reports a failed request for the brand tab" do
    expect(load_brand).to include('I18n.t("extensions.loadFailed")')
  end
end
