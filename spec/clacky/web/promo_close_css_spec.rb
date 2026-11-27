# frozen_string_literal: true

RSpec.describe "Promo dismiss button styling" do
  let(:styles) { File.read(File.expand_path("../../../lib/clacky/web/app.css", __dir__)) }
  let(:settings) { File.read(File.expand_path("../../../lib/clacky/web/settings.js", __dir__)) }
  let(:markup) { File.read(File.expand_path("../../../lib/clacky/web/index.html", __dir__)) }

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
    block = styles[/^\.promo-close:hover \{[^}]*\}/]

    expect(block).to include("background: color-mix(in srgb, var(--color-text-primary) 9%, transparent)")
    expect(block).to include("color: var(--color-text-primary)")
    expect(block).not_to match(/opacity\s*:\s*[01]/)
  end

  it "renders its own dismiss button inside the model-modal promo" do
    hint = settings[settings.index("function _showPromoHint(")...settings.index("function _bindCardEvents(")]

    expect(hint).to include('class="promo-close"')
    expect(hint).to include("_dismissModelModalPromo")
    expect(hint).to include("promo-head")
  end

  it "reveals the hint's dismiss button on hover and for keyboard focus" do
    reveal = rule('\.provider-promo-hint:hover \.promo-close,\s*\.provider-promo-hint:focus-within \.promo-close')

    expect(reveal).to include("opacity: 1")
  end

  it "lets the hint's dismiss button reuse the shared hover disc" do
    expect(styles).not_to include(".provider-promo-hint .promo-close:hover")
    expect(styles).to include(".provider-promo-hint:hover .promo-close")
  end

  # A <button> inside a <label> becomes that label's control, so a click anywhere
  # in the field fires it — the promo would close on any click, and the click it
  # synthesises also reaches the document listener that shuts the provider dropdown.
  it "keeps the promo hint out of the provider field's label" do
    expect(markup).to include('<div class="model-field" id="model-modal-provider-field">')
    expect(markup).not_to match(/<label[^>]*id="model-modal-provider-field"/)

    field = markup[markup.index('id="model-modal-provider-field"')...markup.index('id="model-modal-promo-hint"')]
    expect(field).not_to include("<label")
  end
end
