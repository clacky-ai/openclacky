# frozen_string_literal: true

RSpec.describe Clacky::Config do
  describe ".load" do
    context "when config file doesn't exist" do
      it "returns a new config with default values" do
        with_temp_config do |config_file|
          FileUtils.rm_f(config_file) # Ensure it doesn't exist

          config = described_class.load(config_file)
          expect(config.api_key).to be_nil
          expect(config.model).to eq("gpt-3.5-turbo")
          expect(config.base_url).to eq("https://api.openai.com")
        end
      end
    end

    context "when config file exists" do
      it "loads configuration from file" do
        with_temp_config({
          "api_key" => "test-key",
          "model" => "gpt-4",
          "base_url" => "https://api.test.com"
        }) do |config_file|
          config = described_class.load(config_file)

          expect(config.api_key).to eq("test-key")
          expect(config.model).to eq("gpt-4")
          expect(config.base_url).to eq("https://api.test.com")
        end
      end
    end
  end

  describe "#save" do
    it "saves configuration to file" do
      with_temp_config do |config_file|
        config = described_class.new("api_key" => "my-api-key")
        config.save(config_file)

        expect(File).to exist(config_file)
        saved_data = YAML.load_file(config_file)
        expect(saved_data["api_key"]).to eq("my-api-key")
      end
    end

    it "creates config directory if it doesn't exist" do
      Dir.mktmpdir do |dir|
        config_file = File.join(dir, "nested", "config.yml")

        config = described_class.new("api_key" => "test-key")
        config.save(config_file)

        expect(Dir).to exist(File.dirname(config_file))
      end
    end

    it "sets secure file permissions" do
      with_temp_config do |config_file|
        config = described_class.new("api_key" => "secure-key")
        config.save(config_file)

        file_stat = File.stat(config_file)
        permissions = file_stat.mode.to_s(8)[-3..]
        expect(permissions).to eq("600")
      end
    end
  end

  describe "#to_yaml" do
    it "converts config to YAML format" do
      config = described_class.new({
        "api_key" => "test-key",
        "model" => "gpt-4",
        "base_url" => "https://api.test.com"
      })
      yaml = config.to_yaml

      expect(yaml).to include("api_key: test-key")
      expect(yaml).to include("model: gpt-4")
      expect(yaml).to include("base_url: https://api.test.com")
    end
  end
end
