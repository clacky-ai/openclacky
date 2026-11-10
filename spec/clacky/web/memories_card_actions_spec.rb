# frozen_string_literal: true

RSpec.describe "Memory card action buttons" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)    { File.read(File.join(web_dir, "features/profile/view.js")) }
  let(:styles)  { File.read(File.join(web_dir, "app.css")) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }
  let(:page)    { File.read(File.join(web_dir, "index.html")) }

  it "renders the card actions as icon-only buttons" do
    expect(view.scan(/class="btn-memory-(?:curate|edit|delete|expand)"/).size).to eq(4)
    # Labels repeat on every row of the list, so they only live in the tooltip now.
    expect(view).not_to include('_t("memories.curate")}</span>')
    expect(view).not_to include('_t("memories.edit")}</span>')
    expect(view).not_to include('_t("memories.delete")}</span>')
  end

  it "keeps an accessible name on every icon button" do
    expect(view.scan(/class="btn-memory-\w+"[^>]*aria-label=/).size).to eq(4)
  end

  it "shows the shared tooltip on the icon buttons only" do
    expect(view.scan(/class="btn-memory-(?:curate|edit|delete|expand)" data-tooltip=/).size).to eq(4)
    expect(view).not_to match(/class="btn-memory-\w+"[^>]*\stitle=/)
    # The list reload button carries a text label, so it needs no tooltip.
    tag = page[/<button id="btn-memories-refresh-list".*?>/m]
    expect(tag).not_to be_nil
    expect(tag).not_to include("data-tooltip", "data-i18n-tooltip", " title=")
  end

  it "sizes all four buttons and their glyphs the same" do
    expect(styles).to match(
      /\.btn-memory-curate,\s*\.btn-memory-edit,\s*\.btn-memory-delete,\s*\.btn-memory-expand\s*\{\s*width: 1\.875rem;\s*height: 1\.875rem;/
    )
    expect(styles).to match(
      /\.btn-memory-expand svg\s*\{\s*width: 0\.8125rem;\s*height: 0\.8125rem;\s*\}/
    )
  end

  it "keeps the icon buttons readable instead of placeholder grey" do
    block = styles[/\.btn-memory-curate,\s*\.btn-memory-edit,\s*\.btn-memory-delete,\s*\.btn-memory-expand\s*\{[^}]*\}/]
    expect(block).not_to be_nil
    expect(block).to include("color: var(--color-text-secondary)")
    expect(styles[/\.btn-memories-mini\s*\{[^}]*\}/]).to include("color: var(--color-text-secondary)")
  end

  it "no longer hides button labels on narrow screens" do
    expect(styles).not_to include(".btn-memory-curate span")
    expect(styles).not_to include(".btn-memory-delete span")
  end

  it "draws the list reload glyph instead of a text arrow" do
    expect(i18n).not_to include('"memories.reloadList":    "↻')
    expect(page).to match(
      /id="btn-memories-refresh-list".*?<svg.*?<\/svg>\s*<span data-i18n="memories.reloadList">/m
    )
  end

  it "shares the toolbar button shape and hover with the other pages" do
    block = styles[/\.btn-memories-mini\s*\{[^}]*\}/]
    expect(block).to include("height: 1.75rem", "border-radius: 6px", "font-size: 0.75rem")
    expect(styles[/\.btn-memories-mini:hover\s*\{[^}]*\}/]).to include("background: var(--color-bg-hover)")
  end
end
