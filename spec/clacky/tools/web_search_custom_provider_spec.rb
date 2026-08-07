# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Clacky::Tools::WebSearch, "configured searcher" do
  let(:tool) { described_class.new }

  before do
    @dir = Dir.mktmpdir("clacky_web_search_custom_spec")
    FileUtils.mkdir_p(File.join(@dir, "searchers"))
    stub_const("Clacky::SearchConfig::CONFIG_PATH", File.join(@dir, "search.yml"))
    stub_const("Clacky::Utils::SearcherManager::SEARCHERS_DIR", File.join(@dir, "searchers"))
  end

  after { FileUtils.rm_rf(@dir) }

  def install_searcher(body)
    path = File.join(@dir, "searchers", "fake.rb")
    File.write(path, body)
    Clacky::SearchConfig.save(provider: "fake", key: "secret-key")
    path
  end

  it "returns results from the configured searcher without touching the built-ins" do
    install_searcher(<<~RUBY)
      require "json"
      puts JSON.generate([{ "title" => "T1", "url" => "https://example.com/1", "snippet" => "S1" }])
    RUBY
    expect(tool).not_to receive(:search_duckduckgo)
    expect(tool).not_to receive(:search_bing)

    result = tool.execute(query: "anything")

    expect(result[:error]).to be_nil
    expect(result[:provider]).to eq("fake")
    expect(result[:results]).to eq([{ title: "T1", url: "https://example.com/1", snippet: "S1" }])
  end

  it "passes the query, max_results and key to the searcher" do
    install_searcher(<<~RUBY)
      require "json"
      puts JSON.generate([{
        "title" => ARGV[0], "url" => "https://example.com/\#{ARGV[1]}",
        "snippet" => ENV["CLACKY_SEARCH_KEY"].to_s
      }])
    RUBY

    result = tool.execute(query: "ruby lang", max_results: 3)

    expect(result[:results].first[:title]).to eq("ruby lang")
    expect(result[:results].first[:url]).to eq("https://example.com/3")
    expect(result[:results].first[:snippet]).to eq("secret-key")
  end

  it "caps results at max_results" do
    install_searcher(<<~RUBY)
      require "json"
      puts JSON.generate(Array.new(10) { |i| { "title" => "t\#{i}", "url" => "https://example.com/\#{i}" } })
    RUBY

    expect(tool.execute(query: "q", max_results: 2)[:count]).to eq(2)
  end

  it "drops entries without a URL" do
    install_searcher(<<~RUBY)
      require "json"
      puts JSON.generate([{ "title" => "no url" }, { "title" => "ok", "url" => "https://example.com" }])
    RUBY

    expect(tool.execute(query: "q")[:results].map { |r| r[:title] }).to eq(["ok"])
  end

  it "falls back to the built-in providers when the searcher fails" do
    install_searcher("warn 'bad key'\nexit 1\n")
    allow(tool).to receive(:search_duckduckgo).and_return(
      [{ title: "ddg", url: "https://example.com", snippet: "" }]
    )

    result = tool.execute(query: "q")

    expect(result[:provider]).to eq("duckduckgo")
    expect(result[:error]).to be_nil
  end

  it "falls back when the searcher emits invalid JSON" do
    install_searcher("puts 'not json'\n")
    allow(tool).to receive(:search_duckduckgo).and_return(
      [{ title: "ddg", url: "https://example.com", snippet: "" }]
    )

    expect(tool.execute(query: "q")[:provider]).to eq("duckduckgo")
  end

  it "ignores an unset provider and uses the built-ins" do
    allow(tool).to receive(:search_duckduckgo).and_return(
      [{ title: "ddg", url: "https://example.com", snippet: "" }]
    )

    expect(tool.execute(query: "q")[:provider]).to eq("duckduckgo")
  end
end
