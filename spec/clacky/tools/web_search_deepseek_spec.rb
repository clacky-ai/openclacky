# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Clacky::Tools::WebSearch, "DeepSeek hosted search" do
  let(:tool) { described_class.new }
  let(:config) do
    Clacky::AgentConfig.new(models: [
      {
        "model" => "deepseek-v4-pro", "api_key" => "sk-deepseek",
        "base_url" => "https://api.deepseek.com", "provider_id" => "deepseekv4", "type" => "default"
      }
    ])
  end

  before do
    @dir = Dir.mktmpdir("clacky_web_search_deepseek")
    stub_const("Clacky::SearchConfig::CONFIG_PATH", File.join(@dir, "search.yml"))
    Clacky::SearchConfig.save(provider: Clacky::SearchConfig::DEEPSEEK_WEB, key: "")
    tool.agent = double("agent", config: config)
    # Keep the You.com free tier off the network; web_search_you_spec covers it.
    allow(tool).to receive(:search_you).and_return([])
  end

  after { FileUtils.rm_rf(@dir) }

  let(:deepseek_hit) { [{ title: "DeepSeek hit", url: "https://example.com/ds", snippet: "summary" }] }
  let(:free_hit) { [{ title: "Free hit", url: "https://example.com/free", snippet: "free" }] }

  it "uses DeepSeek before the free engines" do
    allow(Clacky::DeepSeekWebTools).to receive(:search).and_return(deepseek_hit)
    allow(tool).to receive(:search_parallel)
    allow(tool).to receive(:search_duckduckgo)
    allow(tool).to receive(:search_bing)

    result = tool.execute(query: "ruby")

    expect(result[:provider]).to eq("deepseek")
    expect(result[:results]).to eq(deepseek_hit)
    expect(Clacky::DeepSeekWebTools).to have_received(:search)
      .with(hash_including(api_key: "sk-deepseek", base_url: "https://api.deepseek.com"))
    expect(tool).not_to have_received(:search_parallel)
    expect(tool).not_to have_received(:search_duckduckgo)
    expect(tool).not_to have_received(:search_bing)
  end

  it "falls back to the free engines when DeepSeek fails" do
    allow(Clacky::DeepSeekWebTools).to receive(:search).and_raise(StandardError.new("HTTP 402"))
    allow(tool).to receive(:search_parallel).and_return(free_hit)

    result = tool.execute(query: "ruby")

    expect(result[:provider]).to eq("parallel")
    expect(result[:results]).to eq(free_hit)
    expect(result[:error]).to be_nil
    expect(Clacky::DeepSeekWebTools).to be_cooling_down
  end

  it "skips DeepSeek during the cooldown after a failure" do
    allow(Clacky::DeepSeekWebTools).to receive(:search).and_raise(StandardError.new("HTTP 402"))
    allow(tool).to receive(:search_parallel).and_return(free_hit)
    tool.execute(query: "ruby")

    allow(Clacky::DeepSeekWebTools).to receive(:search).and_return(deepseek_hit)
    result = tool.execute(query: "ruby again")

    expect(result[:provider]).to eq("parallel")
    expect(Clacky::DeepSeekWebTools).to have_received(:search).once
  end

  it "reports both failures when DeepSeek and the free engines are down" do
    allow(Clacky::DeepSeekWebTools).to receive(:search).and_raise(StandardError.new("HTTP 402"))
    allow(tool).to receive(:search_parallel).and_raise(StandardError.new("Parallel down"))
    allow(tool).to receive(:search_duckduckgo).and_raise(StandardError.new("DDG down"))
    allow(tool).to receive(:search_bing).and_raise(StandardError.new("Bing down"))

    result = tool.execute(query: "ruby")

    expect(result[:results]).to eq([])
    expect(result[:error]).to include("DeepSeek web search failed")
    expect(result[:error]).to include("Bing down")
  end

  it "skips DeepSeek while another provider is selected" do
    Clacky::SearchConfig.save(provider: "", key: "")
    allow(Clacky::DeepSeekWebTools).to receive(:search)
    allow(tool).to receive(:search_parallel).and_return(free_hit)

    result = tool.execute(query: "ruby")

    expect(result[:provider]).to eq("parallel")
    expect(Clacky::DeepSeekWebTools).not_to have_received(:search)
  end

  it "skips DeepSeek when no key can be resolved" do
    tool.agent = double("agent", config: Clacky::AgentConfig.new(models: []))
    allow(Clacky::DeepSeekWebTools).to receive(:search)
    allow(tool).to receive(:search_parallel).and_return(free_hit)

    result = tool.execute(query: "ruby")

    expect(result[:provider]).to eq("parallel")
    expect(Clacky::DeepSeekWebTools).not_to have_received(:search)
    expect(Clacky::DeepSeekWebTools).not_to be_cooling_down
  end
end
