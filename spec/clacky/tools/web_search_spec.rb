# frozen_string_literal: true

RSpec.describe Clacky::Tools::WebSearch do
  let(:tool) { described_class.new }

  describe "#execute" do
    # A searcher configured on the dev machine would run in a subprocess and
    # bypass the Net::HTTP stubs below, so pin the config off.
    before { allow(Clacky::SearchConfig).to receive(:script_path).and_return(nil) }

    it "returns error for empty query" do
      result = tool.execute(query: "")

      expect(result[:error]).to include("cannot be empty")
    end

    it "returns error for nil query" do
      result = tool.execute(query: nil)

      expect(result[:error]).to include("cannot be empty")
    end

    # Note: Actual web search tests would require network access or mocking
    # For now, we test the basic structure and error handling
    it "handles network errors gracefully" do
      # Stub `start`, not `request`: the latter runs after the real DNS +
      # TLS handshake has already been paid for.
      allow(Net::HTTP).to receive(:start).and_raise(StandardError.new("Network error"))

      result = tool.execute(query: "test query")

      # All providers failed — should return an error message
      expect(result[:error]).to include("All search providers failed")
      expect(result[:results]).to be_empty
    end

    it "respects max_results parameter" do
      # Ten canned hits from the first provider — no network, and the cap is
      # what's under test, not the scraping.
      html = (1..10).map do |i|
        %(<a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fe#{i}.com">Hit #{i}</a>)
      end.join
      ok = Net::HTTPOK.new("1.1", "200", "OK")
      allow(ok).to receive(:body).and_return(html)
      allow(Net::HTTP).to receive(:start).and_return(ok)

      result = tool.execute(query: "ruby programming", max_results: 5)

      expect(result[:query]).to eq("ruby programming")
      expect(result[:count]).to be <= 5
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("web_search")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("query")
      expect(definition[:function][:parameters][:properties]).to have_key(:max_results)
    end
  end
end
