# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Clacky::SearchConfig do
  before do
    @dir = Dir.mktmpdir("clacky_search_config")
    stub_const("Clacky::SearchConfig::CONFIG_PATH", File.join(@dir, "search.yml"))
    Clacky::DeepSeekWebTools.reset_cooldown!
  end

  after { FileUtils.rm_rf(@dir) }

  describe ".load" do
    it "defaults to the free engine chain when no config exists" do
      expect(described_class.load).to eq("provider" => "", "keys" => {})
    end

    it "reads a saved DeepSeek choice" do
      described_class.save(provider: described_class::DEEPSEEK_WEB, key: "")

      expect(described_class.load["provider"]).to eq("deepseek_web")
      expect(described_class.deepseek_web?).to be true
    end

    it "keeps a blank provider, which means built-in engines only" do
      described_class.save(provider: "", key: "")

      expect(described_class.load["provider"]).to eq("")
      expect(described_class.deepseek_web?).to be false
    end

    it "reads provider and per-provider keys" do
      File.write(described_class::CONFIG_PATH,
                 { "provider" => "tavily", "keys" => { "tavily" => "tvly-1", "deepseek_web" => "sk-1" } }.to_yaml)

      expect(described_class.load).to eq("provider" => "tavily",
                                         "keys" => { "tavily" => "tvly-1", "deepseek_web" => "sk-1" })
      expect(described_class.key).to eq("tvly-1")
    end

    it "assigns a legacy single key to the provider it was saved with" do
      File.write(described_class::CONFIG_PATH, { "provider" => "tavily", "key" => "tvly-1" }.to_yaml)

      expect(described_class.load["keys"]).to eq("tavily" => "tvly-1")
    end

    it "drops a legacy key that belongs to no provider" do
      File.write(described_class::CONFIG_PATH, { "provider" => "", "key" => "tvly-1" }.to_yaml)

      expect(described_class.load["keys"]).to eq({})
    end

    it "tolerates malformed YAML instead of raising" do
      File.write(described_class::CONFIG_PATH, "provider: [unclosed")

      expect(described_class.load["provider"]).to eq("")
    end

    it "tolerates a non-Hash document" do
      File.write(described_class::CONFIG_PATH, "- just\n- a list\n")

      expect(described_class.key).to eq("")
    end
  end

  describe ".save" do
    it "persists values and restricts file permissions" do
      described_class.save(provider: "tavily", key: "tvly-1")

      expect(described_class.load).to eq("provider" => "tavily", "keys" => { "tavily" => "tvly-1" })
      expect(File.stat(described_class::CONFIG_PATH).mode & 0o777).to eq(0o600)
    end

    it "keeps omitted fields untouched" do
      described_class.save(provider: "tavily", key: "tvly-1")
      described_class.save(key: "tvly-2")

      expect(described_class.load).to eq("provider" => "tavily", "keys" => { "tavily" => "tvly-2" })
    end

    it "keeps each provider's key when switching between providers" do
      described_class.save(provider: "tavily", key: "tvly-1")
      described_class.save(provider: described_class::DEEPSEEK_WEB, key: "")

      expect(described_class.key).to eq("")
      expect(described_class.key_for("tavily")).to eq("tvly-1")

      described_class.save(provider: described_class::DEEPSEEK_WEB, key: "sk-1")
      described_class.save(provider: "tavily")

      expect(described_class.key).to eq("tvly-1")
      expect(described_class.key_for(described_class::DEEPSEEK_WEB)).to eq("sk-1")
    end

    it "writes only the per-provider layout" do
      File.write(described_class::CONFIG_PATH, { "provider" => "tavily", "key" => "tvly-1" }.to_yaml)
      described_class.save(provider: "tavily")

      expect(YAML.load_file(described_class::CONFIG_PATH)).to eq("provider" => "tavily", "keys" => { "tavily" => "tvly-1" })
    end

    it "clears a DeepSeek cooldown so a new setting takes effect immediately" do
      Clacky::DeepSeekWebTools.mark_unavailable!
      expect(Clacky::DeepSeekWebTools).to be_cooling_down

      described_class.save(provider: "tavily", key: "tvly-1")

      expect(Clacky::DeepSeekWebTools).not_to be_cooling_down
    end
  end

  describe ".deepseek_web?" do
    it "is true only when DeepSeek is the selected provider" do
      described_class.save(provider: described_class::DEEPSEEK_WEB, key: "")
      expect(described_class.deepseek_web?).to be true

      described_class.save(provider: "tavily")
      expect(described_class.deepseek_web?).to be false

      described_class.save(provider: "")
      expect(described_class.deepseek_web?).to be false
    end
  end

  describe ".script_path" do
    it "is nil while no provider is selected" do
      expect(described_class.script_path).to be_nil
    end

    it "is nil for the bundled DeepSeek provider, which has no script" do
      described_class.save(provider: described_class::DEEPSEEK_WEB)

      expect(described_class.script_path).to be_nil
    end

    it "resolves a configured provider to its installed script" do
      Dir.mktmpdir do |searchers|
        stub_const("Clacky::Utils::SearcherManager::SEARCHERS_DIR", searchers)
        File.write(File.join(searchers, "mine.rb"), "# searcher\n")
        allow(Clacky::Utils::SearcherManager).to receive(:available).and_return(["mine"])
        allow(Clacky::Utils::SearcherManager).to receive(:path_for) do |name|
          path = File.join(searchers, "#{name}.rb")
          File.exist?(path) ? path : nil
        end
        described_class.save(provider: "mine")

        expect(described_class.script_path).to eq(File.join(searchers, "mine.rb"))
      end
    end

    it "is nil when the configured provider is not installed" do
      allow(Clacky::Utils::SearcherManager).to receive(:path_for).and_return(nil)
      described_class.save(provider: "ghost")

      expect(described_class.script_path).to be_nil
    end
  end
end
