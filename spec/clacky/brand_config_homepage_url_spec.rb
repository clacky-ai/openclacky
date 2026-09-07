# frozen_string_literal: true

require "spec_helper"
require "clacky/brand_config"

RSpec.describe Clacky::BrandConfig do
  def config_with(url)
    described_class.new("homepage_url" => url)
  end

  describe "#homepage_url" do
    it "prepends https:// to a bare domain" do
      expect(config_with("www.superjiujiu.top").homepage_url).to eq("https://www.superjiujiu.top")
      expect(config_with("superjiujiu.top").homepage_url).to eq("https://superjiujiu.top")
    end

    it "keeps an existing scheme untouched" do
      expect(config_with("https://www.superjiujiu.top").homepage_url).to eq("https://www.superjiujiu.top")
      expect(config_with("http://example.com").homepage_url).to eq("http://example.com")
    end

    # A bare domain resolves as a relative path in the browser, which is what
    # sent users to localhost:7070/<domain>; a path suffix must survive.
    it "prepends https:// to a bare domain carrying a path or query" do
      expect(config_with("example.com/buy?ref=1").homepage_url).to eq("https://example.com/buy?ref=1")
    end

    it "does not rewrite non-http schemes" do
      expect(config_with("mailto:sales@example.com").homepage_url).to eq("mailto:sales@example.com")
    end

    it "returns nil when unset or blank" do
      expect(config_with(nil).homepage_url).to be_nil
      expect(config_with("").homepage_url).to be_nil
      expect(config_with("   ").homepage_url).to be_nil
    end

    it "trims surrounding whitespace before normalizing" do
      expect(config_with("  example.com  ").homepage_url).to eq("https://example.com")
    end

    it "exposes the normalized value through #to_h" do
      expect(config_with("example.com").to_h[:homepage_url]).to eq("https://example.com")
    end

    # brand.yml must keep whatever the platform sent; normalization is a read
    # concern, so a round-trip never rewrites the vendor's stored value.
    it "persists the raw value in #to_yaml" do
      expect(config_with("example.com").to_yaml).to include("homepage_url: example.com")
    end
  end
end
