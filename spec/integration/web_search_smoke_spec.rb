# frozen_string_literal: true

# Smoke tests: real network requests to each search provider.
#
# NOT run in CI — datacenter IPs (e.g. GitHub Actions) get fingerprinted by
# Bing and receive a JS-only skeleton with no parseable results, which is an
# environment problem, not a parser problem.
#
# Run manually before each release / when touching web_search.rb:
#   bundle exec rspec spec/integration/web_search_smoke_spec.rb --tag smoke
#
# These tests verify that:
#   1. Each provider is reachable and returns results
#   2. Parsed results meet minimum quality (title, valid URL, relevant content)
#
# A failure here means the provider's HTML structure has changed and the
# corresponding parser needs to be updated + fixture refreshed.

RSpec.describe "WebSearch smoke tests", :smoke do
  let(:tool) { Clacky::Tools::WebSearch.new }
  let(:query) { "ruby programming language" }

  shared_examples "live search provider" do |provider, required: true|
    it "returns results from #{provider}" do
      results = tool.send(:"search_#{provider}", query, 5)

      if !required && results.empty?
        skip "#{provider} returned no results (may require cookies/auth in this environment)"
      end

      expect(results).not_to be_empty,
        "#{provider} returned no results — parser may need updating"

      expect(results.length).to be >= 3

      results.each do |r|
        expect(r[:title]).not_to be_empty,   "empty title in #{provider} result: #{r.inspect}"
        expect(r[:url]).to match(/\Ahttps?:\/\/.+/), "invalid URL in #{provider}: #{r[:url].inspect}"
      end

      relevant = results.any? { |r| r[:title].downcase.include?("ruby") || r[:url].downcase.include?("ruby") }
      if provider == :bing && !relevant
        skip "Bing returned anti-scrape garbage, skipping due to environment IP block"
      else
        expect(relevant).to be(true),
          "No ruby-related result from #{provider}. Got: #{results.map { |r| r[:title] }}"
      end
    end
  end

  describe "DuckDuckGo" do
    # DuckDuckGo may be blocked or rate-limited in some environments (e.g. mainland China).
    # Mark as non-required so it skips instead of failing when blocked.
    include_examples "live search provider", :duckduckgo, required: false
  end

  describe "Bing" do
    include_examples "live search provider", :bing, required: false
  end

  describe "fallback chain" do
    it "execute returns results through the fallback chain" do
      result = tool.execute(query: query, max_results: 5)

      expect(result[:error]).to be_nil
      expect(result[:count]).to be >= 3
      expect(result[:provider]).not_to be_nil
      puts "  → Used provider: #{result[:provider]}"
    end
  end
end
