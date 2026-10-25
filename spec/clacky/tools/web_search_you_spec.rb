# frozen_string_literal: true

require "json"

RSpec.describe Clacky::Tools::WebSearch, "You.com provider" do
  let(:tool) { described_class.new }
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(Clacky::SearchConfig).to receive(:script_path).and_return(nil)
    allow(tool).to receive(:search_parallel).and_raise(StandardError.new("Parallel unavailable"))
  end

  def you_response(code, body, headers = {})
    klass = Net::HTTPResponse::CODE_TO_OBJ[code.to_s]
    response = klass.new("1.1", code.to_s, "")
    headers.each { |k, v| response[k] = v }
    allow(response).to receive(:body).and_return(body)
    response
  end

  def stub_you(response)
    captured = {}
    allow(Net::HTTP).to receive(:start) do |host, *_args, **_kw, &block|
      captured[:host] = host
      allow(http).to receive(:request) do |req|
        captured[:request] = req
        response
      end
      block.call(http)
    end
    captured
  end

  let(:payload) do
    {
      "results" => {
        "web" => [
          { "url" => "https://www.ruby-lang.org/", "title" => "Ruby", "description" => "A  dynamic\nlanguage",
            "snippets" => ["ignored"] },
          { "url" => "https://example.com/s", "title" => "Snippets only", "description" => "",
            "snippets" => ["one", "two"] },
          { "url" => "", "title" => "No URL" }
        ]
      }
    }
  end

  it "runs after Parallel and before the HTML scrapers, without a key" do
    captured = stub_you(you_response(200, JSON.generate(payload)))
    expect(tool).not_to receive(:search_duckduckgo)
    expect(tool).not_to receive(:search_bing)

    result = tool.execute(query: "ruby lang", max_results: 5)

    expect(result[:provider]).to eq("you")
    expect(result[:count]).to eq(2)
    expect(result[:results].first).to eq(
      title: "Ruby", url: "https://www.ruby-lang.org/", snippet: "A dynamic language"
    )
    expect(result[:results].last[:snippet]).to eq("one two")

    request = captured[:request]
    expect(captured[:host]).to eq("api.you.com")
    expect(request.path).to start_with("/v1/agents/search?")
    expect(URI.decode_www_form(URI(request.path).query).to_h).to eq("query" => "ruby lang", "count" => "5")
    expect(request["User-Agent"]).to eq("youdotcom-integration/clacky-ai-openclacky")
    expect(request["X-API-Key"]).to be_nil
  end

  it "respects max_results" do
    stub_you(you_response(200, JSON.generate(payload)))

    expect(tool.execute(query: "ruby", max_results: 1)[:count]).to eq(1)
  end

  it "falls back to DuckDuckGo on 429 and honors Retry-After for the cooldown" do
    stub_you(you_response(429, "{}", "Retry-After" => "120"))
    allow(tool).to receive(:search_duckduckgo).and_return(
      [{ title: "DDG", url: "https://example.com/ddg", snippet: "" }]
    )

    result = tool.execute(query: "ruby")
    expect(result[:provider]).to eq("duckduckgo")

    cooldown = tool.instance_variable_get(:@you_unavailable_until)
    expect(cooldown).to be_within(5).of(Time.now + 120)

    expect(tool).not_to receive(:search_you)
    tool.execute(query: "ruby")
  end

  it "cools down for the shared window on quota and auth errors" do
    [402, 403, 401].each do |code|
      fresh = described_class.new
      allow(fresh).to receive(:search_parallel).and_raise(StandardError.new("down"))
      allow(fresh).to receive(:search_duckduckgo).and_return([])
      allow(fresh).to receive(:search_bing).and_return([])
      stub_you(you_response(code, "{}"))

      result = fresh.execute(query: "ruby")

      expect(result[:error]).to include("You.com search failed").or include("All search providers failed")
      expect(fresh.instance_variable_get(:@you_unavailable_until))
        .to be_within(5).of(Time.now + described_class::PROVIDER_COOLDOWN_SECONDS)
    end
  end

  it "treats a malformed body as a failure" do
    stub_you(you_response(200, "not json"))
    allow(tool).to receive(:search_duckduckgo).and_return([])
    allow(tool).to receive(:search_bing).and_return([])

    expect(tool.execute(query: "ruby")[:error]).to include("You.com returned malformed JSON")
  end
end
