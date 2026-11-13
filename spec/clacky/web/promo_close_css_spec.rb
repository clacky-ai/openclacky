# frozen_string_literal: true

RSpec.describe "Promo dismiss button styling" do
  let(:styles) { File.read(File.expand_path("../../../lib/clacky/web/app.css", __dir__)) }
  let(:settings) { File.read(File.expand_path("../../../lib/clacky/web/settings.js", __dir__)) }

  def rule(selector)
    block = styles[/#{selector}\s*\{[^}]*\}/]
    raise "#{selector} rule not found" unless block

    block
  end

  it "keeps the dismiss button invisible until the promo is hovered" do
    expect(rule('\.promo-close')).to include("opacity: 0")
  end

  it "reveals the button for the media banner on hover and for keyboard focus" do
    reveal = rule('\.media-promo:hover \.promo-close,\s*\.media-promo:focus-within \.promo-close')

    expect(reveal).to include("opacity: 1")
    expect(reveal).not_to include("background")
  end

  it "keeps the button visible on touch devices and when focused" do
    expect(rule('\.promo-close:focus-visible')).to include("opacity: 1")
    expect(styles).to match(/@media \(hover: none\) \{\s*\.promo-close \{ opacity: 1; \}/)
  end

  it "paints a grey disc only when the dismiss button itself is hovered" do
    block = rule('\.promo-close:hover')

    expect(block).to include("background: color-mix(in srgb, var(--color-text-primary) 9%, transparent)")
    expect(block).to include("color: var(--color-text-primary)")
    expect(block).not_to match(/opacity\s*:\s*[01]/)
  end

  it "renders no dismiss button inside the model-modal promo" do
    hint = settings[settings.index("function _showPromoHint(")...settings.index("function _bindCardEvents(")]

    expect(hint).not_to include("_promoCloseButton")
    expect(hint).not_to include("promo-close")
    expect(hint).to include("promo-head")
  end
end
