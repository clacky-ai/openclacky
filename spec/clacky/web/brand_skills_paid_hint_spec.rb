# frozen_string_literal: true

RSpec.describe "Brand skills paid hint" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }
  let(:styles)  { File.read(File.join(web_dir, "app.css")) }

  it "asks for the brand serial number, not a bare serial number" do
    zh = i18n.scan(/"skills\.brand\.paidHint":\s*"([^"]+)"/).flatten.last
    expect(zh).to include("激活品牌序列号")
  end

  it "styles the activation button as a primary button in the brand accent" do
    rule = styles[/^\.brand-skills-activate-btn \{(.*?)^\}/m, 1]
    expect(rule).not_to be_nil
    expect(rule).to include("background: var(--color-button-primary)")
    expect(rule).to include("color: var(--color-button-primary-text)")
    expect(rule).not_to include("--color-accent,")
  end
end
