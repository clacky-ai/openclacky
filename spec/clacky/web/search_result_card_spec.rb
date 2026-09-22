# frozen_string_literal: true

require "open3"

RSpec.describe "Web search result card" do
  it "promotes web_search results into a standalone message card" do
    script = File.expand_path("../../support/search_result_card_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end

  describe "link styling" do
    let(:styles) { File.read(File.expand_path("../../../lib/clacky/web/app.css", __dir__)) }

    # A red or orange accent would paint result titles the same hue as
    # --color-error, so dense link lists get their own fixed palette.
    it "colors titles with a fixed link color, not the user-configurable accent" do
      expect(styles).to include(".search-card-title {\n  color: var(--color-link);")
      expect(styles).not_to include(".search-card-title {\n  color: var(--color-accent-primary);")
    end

    # _applyAccentColor sets --color-accent-primary and --color-accent-hover to the
    # same value, so a hover color swap is dead code once the user picks an accent.
    it "underlines on hover instead of swapping the color" do
      expect(styles).to include(".search-card-item:hover .search-card-title { text-decoration: underline; }")
      expect(styles).not_to include(":hover .search-card-title { color:")
    end

    it "defines the link palette in every theme without deriving it from the accent" do
      expect(styles).to include(".search-card-item:visited .search-card-title { color: var(--color-link-visited); }")
      expect(styles.scan(/^\s*--color-link:/m).size).to eq(5)
      expect(styles.scan(/^\s*--color-link-visited:/m).size).to eq(5)
      expect(styles).not_to match(/--color-link(-visited)?:\s*(color-mix|var\()/)
    end

    it "keeps the accent on the expand toggle, which is an app control not a link" do
      expect(styles).to include(".search-card-more:hover { color: var(--color-accent-primary); }")
    end
  end
end
