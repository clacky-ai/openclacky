# frozen_string_literal: true

# Every dropdown in the web UI (billing model filter, settings pickers, the
# recycle bin type filter) shares `.custom-select-*`. Their hover used to be a
# neutral grey wash / grey border, which read as "disabled" next to the accent
# hover on the surrounding buttons.
RSpec.describe "Custom select hover colours" do
  let(:styles) { File.read(File.expand_path("../../../lib/clacky/web/app.css", __dir__)) }

  def rule(selector)
    block = styles[/#{selector}\s*\{[^}]*\}/]
    raise "#{selector} rule not found" unless block

    block
  end

  it "outlines the trigger in the theme colour on hover" do
    block = rule('\.custom-select-trigger:hover')

    expect(block).to include("border-color: var(--color-accent-primary)")
    expect(block).not_to include("--color-text-muted")
  end

  it "washes the hovered option with the theme colour but keeps its text" do
    block = rule('\.custom-select-option:hover')

    expect(block).to include("color-mix(in srgb, var(--color-accent-primary) 8%, transparent)")
    expect(block).not_to include("--color-bg-hover")
    # Only the selected option may turn accent-coloured, otherwise the rows a
    # user is merely pointing at look identical to the current choice.
    expect(block).not_to match(/color:\s*var\(--color-accent-primary\)/)
  end

  it "keeps the selected option accent-coloured and stronger than hover" do
    block = rule('\.custom-select-option\.selected')

    expect(block).to include("color-mix(in srgb, var(--color-accent-primary) 12%, transparent)")
    expect(block).to include("color: var(--color-accent-primary)")
    expect(block).not_to include("--color-bg-hover")
  end
end
