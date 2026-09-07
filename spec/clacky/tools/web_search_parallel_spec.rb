# frozen_string_literal: true

require "json"

RSpec.describe Clacky::Tools::WebSearch, "Parallel provider" do
  let(:tool) { described_class.new }
  let(:client) { instance_double(Clacky::Mcp::Client) }

  before do
    allow(Clacky::SearchConfig).to receive(:script_path).and_return(nil)
    allow(Clacky::Mcp::Client).to receive(:from_spec).and_return(client)
    allow(client).to receive(:start).and_return(client)
    allow(client).to receive(:stop)
  end

  def parallel_result(results)
    {
      "structuredContent" => {
        "results" => results,
        "warnings" => nil
      },
      "isError" => false
    }
  end

  it "uses Parallel before the HTML scrapers" do
    response = parallel_result([{
      "title" => "Ruby",
      "url" => "https://www.ruby-lang.org/",
      "excerpts" => ["Ruby programming language"]
    }])
    allow(client).to receive(:call_tool).and_return(response)
    expect(tool).not_to receive(:search_duckduckgo)
    expect(tool).not_to receive(:search_bing)

    result = tool.execute(query: "ruby programming")

    expect(result[:provider]).to eq("parallel")
    expect(result[:count]).to eq(1)
  end

  it "caps only the snippet and preserves the full URL" do
    url = "https://example.com/a/very/long/path?source=parallel&item=1"
    response = parallel_result([{
      "title" => "Long result",
      "url" => url,
      "excerpts" => ["x" * 500]
    }])
    allow(client).to receive(:call_tool).and_return(response)

    item = tool.execute(query: "long result")[:results].first

    expect(item[:url]).to eq(url)
    expect(item[:snippet]).to eq("x" * 400)
  end

  it "respects max_results" do
    results = Array.new(10) do |index|
      {
        "title" => "Result #{index}",
        "url" => "https://example.com/#{index}",
        "excerpts" => ["Snippet #{index}"]
      }
    end
    allow(client).to receive(:call_tool).and_return(parallel_result(results))

    result = tool.execute(query: "results", max_results: 3)

    expect(result[:count]).to eq(3)
  end

  it "parses JSON from text content when structured content is absent" do
    payload = {
      "results" => [{
        "title" => "Fallback",
        "url" => "https://example.com/fallback",
        "excerpts" => ["Text content"]
      }]
    }
    allow(client).to receive(:call_tool).and_return(
      "content" => [{ "type" => "text", "text" => JSON.generate(payload) }],
      "isError" => false
    )

    result = tool.execute(query: "fallback")

    expect(result[:results].first[:snippet]).to eq("Text content")
  end

  it "reuses the MCP client and logical session within one tool instance" do
    session_ids = []
    allow(client).to receive(:call_tool) do |_name, arguments|
      session_ids << arguments["session_id"]
      parallel_result([{
        "title" => "Result",
        "url" => "https://example.com",
        "excerpts" => ["Snippet"]
      }])
    end

    tool.execute(query: "first")
    tool.execute(query: "second")

    expect(Clacky::Mcp::Client).to have_received(:from_spec).once
    expect(session_ids.length).to eq(2)
    expect(session_ids.uniq.length).to eq(1)
  end

  it "falls back to DuckDuckGo when Parallel fails" do
    allow(client).to receive(:call_tool).and_raise(Clacky::Mcp::Client::TransportError, "offline")
    allow(tool).to receive(:search_duckduckgo).and_return(
      [{ title: "Fallback", url: "https://example.com", snippet: "DDG" }]
    )

    result = tool.execute(query: "fallback")

    expect(result[:provider]).to eq("duckduckgo")
    expect(client).to have_received(:stop)
  end

  it "skips Parallel during the cooldown after a transport failure" do
    allow(client).to receive(:call_tool).and_raise(Clacky::Mcp::Client::TransportError, "offline")
    allow(tool).to receive(:search_duckduckgo).and_return(
      [{ title: "Fallback", url: "https://example.com", snippet: "DDG" }]
    )

    tool.execute(query: "first")
    tool.execute(query: "second")

    expect(client).to have_received(:call_tool).once
    expect(tool).to have_received(:search_duckduckgo).twice
  end

  it "falls back when Parallel returns an error result" do
    allow(client).to receive(:call_tool).and_return(
      "content" => [{ "type" => "text", "text" => "rate limited" }],
      "isError" => true
    )
    allow(tool).to receive(:search_duckduckgo).and_return(
      [{ title: "Fallback", url: "https://example.com", snippet: "DDG" }]
    )

    expect(tool.execute(query: "fallback")[:provider]).to eq("duckduckgo")
  end

  it "does not invoke Parallel when a custom provider is configured" do
    allow(Clacky::SearchConfig).to receive(:script_path).and_return("/tmp/custom.rb")
    allow(Clacky::SearchConfig).to receive(:load).and_return(
      "provider" => "tavily",
      "api_key" => "configured"
    )
    allow(tool).to receive(:search_custom).and_return(
      [{ title: "Custom", url: "https://example.com", snippet: "custom" }]
    )
    expect(Clacky::Mcp::Client).not_to receive(:from_spec)

    expect(tool.execute(query: "custom")[:provider]).to eq("tavily")
  end
end
