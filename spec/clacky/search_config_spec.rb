# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "yaml"

RSpec.describe Clacky::SearchConfig do
  before do
    @dir = Dir.mktmpdir("clacky_search_config_spec")
    FileUtils.mkdir_p(File.join(@dir, "searchers"))
    stub_const("Clacky::SearchConfig::CONFIG_PATH", File.join(@dir, "search.yml"))
    stub_const("Clacky::Utils::SearcherManager::SEARCHERS_DIR", File.join(@dir, "searchers"))
  end

  after { FileUtils.rm_rf(@dir) }

  def install_searcher(name, body = "puts '[]'")
    path = File.join(@dir, "searchers", "#{name}.rb")
    File.write(path, body)
    path
  end

  describe ".load" do
    it "defaults to blank values when the file is missing" do
      expect(described_class.load).to eq("provider" => "", "key" => "")
    end

    it "reads provider and key" do
      File.write(described_class::CONFIG_PATH, { "provider" => "tavily", "key" => "k1" }.to_yaml)

      expect(described_class.load).to eq("provider" => "tavily", "key" => "k1")
    end

    it "tolerates malformed YAML instead of raising" do
      File.write(described_class::CONFIG_PATH, "\tnot: [valid")

      expect(described_class.load).to eq("provider" => "", "key" => "")
    end

    it "tolerates a non-Hash document" do
      File.write(described_class::CONFIG_PATH, "just a string\n")

      expect(described_class.load).to eq("provider" => "", "key" => "")
    end
  end

  describe ".save" do
    it "persists values and restricts file permissions" do
      described_class.save(provider: " tavily ", key: " k1 ")

      expect(described_class.load).to eq("provider" => "tavily", "key" => "k1")
      expect(File.stat(described_class::CONFIG_PATH).mode & 0o777).to eq(0o600)
    end
  end

  describe ".script_path" do
    it "is nil when no provider is configured" do
      expect(described_class.script_path).to be_nil
    end

    it "resolves a configured provider to its installed script" do
      path = install_searcher("tavily")
      described_class.save(provider: "tavily", key: "k1")

      expect(described_class.script_path).to eq(path)
    end

    it "is nil when the configured provider is not installed" do
      described_class.save(provider: "ghost", key: "k1")

      expect(described_class.script_path).to be_nil
    end
  end
end
