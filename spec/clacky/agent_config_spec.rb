# frozen_string_literal: true

RSpec.describe Clacky::AgentConfig do
  # Helper to create a temporary config file
  def with_temp_config(data = nil)
    temp_dir = Dir.mktmpdir
    config_file = File.join(temp_dir, "config.yml")

    if data
      File.write(config_file, YAML.dump(data))
    end

    yield config_file
  ensure
    FileUtils.rm_rf(temp_dir) if temp_dir
  end

  describe ".load" do
    context "when config file doesn't exist" do
      it "returns a new config with empty models" do
        with_env("ANTHROPIC_API_KEY" => nil, "ANTHROPIC_AUTH_TOKEN" => nil) do
          with_temp_config do |config_file|
            FileUtils.rm_f(config_file) # Ensure it doesn't exist

            config = described_class.load(config_file)
            expect(config.models).to eq([])
            expect(config.models_configured?).to be false
          end
        end
      end

      # context "with ClaudeCode environment variables" do
      #   it "creates a default model from environment variables" do
      #     with_env("ANTHROPIC_API_KEY" => "sk-test-env-key", "ANTHROPIC_BASE_URL" => "https://api.env.test.com") do
      #       with_temp_config do |config_file|
      #         FileUtils.rm_f(config_file)
      #
      #         config = described_class.load(config_file)
      #
      #         expect(config.models.length).to eq(1)
      #         expect(config.models.first["model"]).to eq("claude-sonnet-4-5")
      #         expect(config.models.first["api_key"]).to eq("sk-test-env-key")
      #         expect(config.models.first["base_url"]).to eq("https://api.env.test.com")
      #         expect(config.models.first["anthropic_format"]).to be true
      #       end
      #     end
      #   end
      # end
    end

    context "when config file exists with new top-level array format" do
      it "loads array of models directly" do
        with_temp_config([
          {
            "model" => "claude-sonnet-4",
            "api_key" => "sk-key1",
            "base_url" => "https://api.test.com",
            "anthropic_format" => true
          },
          {
            "model" => "gpt-4",
            "api_key" => "sk-key2",
            "base_url" => "https://api.openai.com",
            "anthropic_format" => false
          }
        ]) do |config_file|
          config = described_class.load(config_file)

          expect(config.models.length).to eq(2)
          expect(config.models[0]["model"]).to eq("claude-sonnet-4")
          expect(config.models[0]["api_key"]).to eq("sk-key1")
          expect(config.models[1]["model"]).to eq("gpt-4")
          expect(config.models[1]["api_key"]).to eq("sk-key2")
        end
      end
    end

    context "backward compatibility with old models: key format" do
      it "loads array under models key" do
        with_temp_config({
          "models" => [
            {
              "model" => "claude-sonnet-4",
              "api_key" => "sk-key1",
              "base_url" => "https://api.test.com",
              "anthropic_format" => true
            },
            {
              "model" => "gpt-4",
              "api_key" => "sk-key2",
              "base_url" => "https://api.openai.com",
              "anthropic_format" => false
            }
          ]
        }) do |config_file|
          config = described_class.load(config_file)

          expect(config.models.length).to eq(2)
          expect(config.models[0]["model"]).to eq("claude-sonnet-4")
          expect(config.models[1]["model"]).to eq("gpt-4")
        end
      end

      it "converts old name field to model field" do
        with_temp_config({
          "models" => [
            {
              "name" => "default",
              "api_key" => "sk-key1",
              "base_url" => "https://api.test.com",
              "anthropic_format" => true
            }
          ]
        }) do |config_file|
          config = described_class.load(config_file)

          expect(config.models.length).to eq(1)
          expect(config.models[0]["model"]).to eq("default")
          expect(config.models[0]["name"]).to be_nil
        end
      end
    end

    context "backward compatibility with old hash format" do
      it "converts old tier-based hash to new array format" do
        with_temp_config({
          "models" => {
            "claude-sonnet-4" => {
              "api_key" => "sk-old-key",
              "base_url" => "https://api.old.com",
              "model_name" => "claude-sonnet-4",
              "anthropic_format" => true
            },
            "claude-opus-4" => {
              "api_key" => "sk-old-key",
              "base_url" => "https://api.old.com",
              "model_name" => "claude-opus-4",
              "anthropic_format" => true
            }
          }
        }) do |config_file|
          config = described_class.load(config_file)

          expect(config.models.length).to eq(2)
          expect(config.models[0]["model"]).to eq("claude-sonnet-4")
          expect(config.models[1]["model"]).to eq("claude-opus-4")
        end
      end

      it "converts very old format with single model" do
        with_temp_config({
          "api_key" => "sk-very-old",
          "base_url" => "https://api.very-old.com",
          "model" => "claude-2",
          "anthropic_format" => false
        }) do |config_file|
          config = described_class.load(config_file)

          expect(config.models.length).to eq(1)
          expect(config.models[0]["api_key"]).to eq("sk-very-old")
          expect(config.models[0]["model"]).to eq("claude-2")
          expect(config.models[0]["anthropic_format"]).to be false
        end
      end
    end
  end

  describe "#save" do
    it "saves configuration as top-level array" do
      with_temp_config do |config_file|
        config = described_class.new(
          models: [
            {
              "model" => "test-model",
              "api_key" => "sk-test",
              "base_url" => "https://api.test.com",
              "anthropic_format" => true
            }
          ]
        )

        config.save(config_file)

        expect(File.exist?(config_file)).to be true
        
        loaded_data = YAML.load_file(config_file)
        expect(loaded_data).to be_a(Array)
        expect(loaded_data.length).to eq(1)
        expect(loaded_data[0]["api_key"]).to eq("sk-test")
        expect(loaded_data[0]["model"]).to eq("test-model")
      end
    end

    it "sets file permissions to 0600" do
      with_temp_config do |config_file|
        config = described_class.new(models: [])
        config.save(config_file)

        stat = File.stat(config_file)
        expect(sprintf("%o", stat.mode & 0o777)).to eq("600")
      end
    end
  end

  describe "#models_configured?" do
    it "returns true when models are configured" do
      config = described_class.new(
        models: [{ "model" => "test-model" }]
      )
      expect(config.models_configured?).to be true
    end

    it "returns false when models array is empty" do
      config = described_class.new(models: [])
      expect(config.models_configured?).to be false
    end
  end

  describe "#current_model" do
    it "returns the first model by default" do
      config = described_class.new(
        models: [
          { "model" => "model-1" },
          { "model" => "model-2" }
        ]
      )
      
      expect(config.current_model["model"]).to eq("model-1")
    end

    it "returns nil when no models configured" do
      config = described_class.new(models: [])
      expect(config.current_model).to be_nil
    end
  end

  describe "#switch_model" do
    let(:config) do
      described_class.new(
        models: [
          { "model" => "model-1" },
          { "model" => "model-2" },
          { "model" => "model-3" }
        ]
      )
    end

    it "switches to model by index" do
      expect(config.switch_model(1)).to be true
      expect(config.current_model["model"]).to eq("model-2")
    end

    it "returns false for out of range index" do
      expect(config.switch_model(10)).to be false
      expect(config.current_model["model"]).to eq("model-1")
    end

    it "returns false for negative index" do
      expect(config.switch_model(-1)).to be false
      expect(config.current_model["model"]).to eq("model-1")
    end
  end

  describe "#get_model" do
    let(:config) do
      described_class.new(
        models: [
          { "model" => "model-1", "api_key" => "key1" },
          { "model" => "model-2", "api_key" => "key2" }
        ]
      )
    end

    it "returns model by index" do
      model = config.get_model(1)
      expect(model["model"]).to eq("model-2")
      expect(model["api_key"]).to eq("key2")
    end

    it "returns nil for out of range index" do
      expect(config.get_model(10)).to be_nil
    end
  end

  describe "#model_names" do
    it "returns array of model names" do
      config = described_class.new(
        models: [
          { "model" => "claude-sonnet-4" },
          { "model" => "gpt-4" },
          { "model" => "custom-model" }
        ]
      )

      expect(config.model_names).to eq(["claude-sonnet-4", "gpt-4", "custom-model"])
    end

    it "returns empty array when no models" do
      config = described_class.new(models: [])
      expect(config.model_names).to eq([])
    end
  end

  describe "#api_key" do
    it "returns api_key for current model" do
      config = described_class.new(
        models: [{ "model" => "test", "api_key" => "sk-test-key" }]
      )
      expect(config.api_key).to eq("sk-test-key")
    end

    it "returns nil when no models" do
      config = described_class.new(models: [])
      expect(config.api_key).to be_nil
    end
  end

  describe "#base_url" do
    it "returns base_url for current model" do
      config = described_class.new(
        models: [{ "model" => "test", "base_url" => "https://api.test.com" }]
      )
      expect(config.base_url).to eq("https://api.test.com")
    end

    it "returns nil when no models" do
      config = described_class.new(models: [])
      expect(config.base_url).to be_nil
    end
  end

  describe "#model_name" do
    it "returns model name for current model" do
      config = described_class.new(
        models: [{ "model" => "claude-sonnet-4" }]
      )
      expect(config.model_name).to eq("claude-sonnet-4")
    end

    it "returns nil when no models" do
      config = described_class.new(models: [])
      expect(config.model_name).to be_nil
    end
  end

  describe "#anthropic_format?" do
    it "returns true when anthropic_format is true" do
      config = described_class.new(
        models: [{ "model" => "test", "anthropic_format" => true }]
      )
      expect(config.anthropic_format?).to be true
    end

    it "returns false when anthropic_format is false" do
      config = described_class.new(
        models: [{ "model" => "test", "anthropic_format" => false }]
      )
      expect(config.anthropic_format?).to be false
    end

    it "returns false when anthropic_format is not set" do
      config = described_class.new(
        models: [{ "model" => "test" }]
      )
      expect(config.anthropic_format?).to be false
    end
  end

  describe "#add_model" do
    it "adds a new model to the array" do
      config = described_class.new(models: [])
      
      config.add_model(
        model: "new-model",
        api_key: "sk-new",
        base_url: "https://api.new.com",
        anthropic_format: true
      )

      expect(config.models.length).to eq(1)
      expect(config.models[0]["model"]).to eq("new-model")
      expect(config.models[0]["api_key"]).to eq("sk-new")
    end

    it "adds multiple models" do
      config = described_class.new(models: [])
      
      config.add_model(model: "model-1", api_key: "key1", base_url: "url1")
      config.add_model(model: "model-2", api_key: "key2", base_url: "url2")

      expect(config.models.length).to eq(2)
      expect(config.model_names).to eq(["model-1", "model-2"])
    end
  end

  describe "#remove_model" do
    let(:config) do
      described_class.new(
        models: [
          { "model" => "model-1" },
          { "model" => "model-2" },
          { "model" => "model-3" }
        ]
      )
    end

    it "removes model by index" do
      expect(config.remove_model(1)).to be true
      expect(config.models.length).to eq(2)
      expect(config.model_names).to eq(["model-1", "model-3"])
    end

    it "returns false when trying to remove last model" do
      single_model_config = described_class.new(
        models: [{ "model" => "only-one" }]
      )
      
      expect(single_model_config.remove_model(0)).to be false
      expect(single_model_config.models.length).to eq(1)
    end

    it "returns false for out of range index" do
      expect(config.remove_model(10)).to be false
      expect(config.models.length).to eq(3)
    end

    it "adjusts current_model_index when necessary" do
      config.switch_model(2) # Switch to last model
      expect(config.current_model["model"]).to eq("model-3")
      
      config.remove_model(2) # Remove last model
      expect(config.current_model["model"]).to eq("model-2")
    end
  end

  describe "permission modes" do
    it "defaults to confirm_safes mode" do
      config = described_class.new
      expect(config.permission_mode).to eq(:confirm_safes)
    end

    it "accepts valid permission modes" do
      config = described_class.new(permission_mode: :auto_approve)
      expect(config.permission_mode).to eq(:auto_approve)
    end

    it "raises error for invalid permission mode" do
      expect {
        described_class.new(permission_mode: :invalid_mode)
      }.to raise_error(ArgumentError, /Invalid permission mode/)
    end
  end

  describe "type field support" do
    describe "#find_model_by_type" do
      it "returns model with specified type" do
        models = [
          { "model" => "sonnet", "type" => "default" },
          { "model" => "haiku", "type" => "lite" },
          { "model" => "opus" }
        ]
        config = described_class.new(models: models)
        
        expect(config.find_model_by_type("default")["model"]).to eq("sonnet")
        expect(config.find_model_by_type("lite")["model"]).to eq("haiku")
        expect(config.find_model_by_type("other")).to be_nil
      end
    end

    describe "#lite_model" do
      it "returns lite model if configured" do
        models = [
          { "model" => "sonnet", "type" => "default" },
          { "model" => "haiku", "type" => "lite" }
        ]
        config = described_class.new(models: models)
        
        expect(config.lite_model["model"]).to eq("haiku")
      end

      it "returns nil if no lite model" do
        models = [{ "model" => "sonnet", "type" => "default" }]
        config = described_class.new(models: models)
        
        expect(config.lite_model).to be_nil
      end
    end

    describe "#current_model" do
      it "returns model with type: default" do
        models = [
          { "model" => "opus" },
          { "model" => "sonnet", "type" => "default" },
          { "model" => "haiku", "type" => "lite" }
        ]
        config = described_class.new(models: models)
        
        expect(config.current_model["model"]).to eq("sonnet")
      end

      it "falls back to index-based for backward compatibility" do
        models = [
          { "model" => "opus" },
          { "model" => "sonnet" }
        ]
        config = described_class.new(models: models, current_model_index: 1)
        
        expect(config.current_model["model"]).to eq("sonnet")
      end
    end

    describe "#switch_model" do
      it "sets type: default on selected model and removes from others" do
        models = [
          { "model" => "opus", "type" => "default" },
          { "model" => "sonnet" },
          { "model" => "haiku", "type" => "lite" }
        ]
        config = described_class.new(models: models)
        
        config.switch_model(1)
        
        expect(config.models[0]["type"]).to be_nil
        expect(config.models[1]["type"]).to eq("default")
        expect(config.models[2]["type"]).to eq("lite")
      end

      it "preserves lite type when switching" do
        models = [
          { "model" => "opus", "type" => "default" },
          { "model" => "haiku", "type" => "lite" }
        ]
        config = described_class.new(models: models)
        
        config.switch_model(1)
        
        expect(config.models[0]["type"]).to be_nil
        expect(config.models[1]["type"]).to eq("default")
      end
    end

    describe "#set_model_type" do
      it "sets type on specified model" do
        models = [
          { "model" => "opus" },
          { "model" => "sonnet" }
        ]
        config = described_class.new(models: models)
        
        config.set_model_type(0, "default")
        config.set_model_type(1, "lite")
        
        expect(config.models[0]["type"]).to eq("default")
        expect(config.models[1]["type"]).to eq("lite")
      end

      it "ensures only one model has each type" do
        models = [
          { "model" => "opus", "type" => "default" },
          { "model" => "sonnet" }
        ]
        config = described_class.new(models: models)
        
        config.set_model_type(1, "default")
        
        expect(config.models[0]["type"]).to be_nil
        expect(config.models[1]["type"]).to eq("default")
      end

      it "removes type when set to nil" do
        models = [{ "model" => "opus", "type" => "default" }]
        config = described_class.new(models: models)
        
        config.set_model_type(0, nil)
        
        expect(config.models[0]["type"]).to be_nil
      end
    end
  end

  describe "ClackyEnv environment variables" do
    describe "default model" do
      it "loads from CLACKY_XXX env vars when config is empty" do
        with_env(
          "CLACKY_API_KEY" => "sk-clacky-test",
          "CLACKY_BASE_URL" => "https://api.clacky.test",
          "CLACKY_MODEL" => "claude-test-model",
          "CLACKY_ANTHROPIC_FORMAT" => "false"
        ) do
          with_temp_config do |config_file|
            FileUtils.rm_f(config_file)
            
            config = described_class.load(config_file)
            
            expect(config.models.length).to eq(1)
            expect(config.models.first["type"]).to eq("default")
            expect(config.models.first["api_key"]).to eq("sk-clacky-test")
            expect(config.models.first["base_url"]).to eq("https://api.clacky.test")
            expect(config.models.first["model"]).to eq("claude-test-model")
            expect(config.models.first["anthropic_format"]).to be false
          end
        end
      end

      it "uses default model name if CLACKY_MODEL not set" do
        with_env("CLACKY_API_KEY" => "sk-test") do
          with_temp_config do |config_file|
            FileUtils.rm_f(config_file)
            
            config = described_class.load(config_file)
            
            expect(config.models.first["model"]).to eq("claude-sonnet-4-5")
          end
        end
      end
    end

    describe "lite model" do
      it "loads from CLACKY_LITE_XXX env vars" do
        with_env(
          "CLACKY_API_KEY" => "sk-default",
          "CLACKY_LITE_API_KEY" => "sk-lite",
          "CLACKY_LITE_MODEL" => "claude-haiku-test"
        ) do
          with_temp_config do |config_file|
            FileUtils.rm_f(config_file)
            
            config = described_class.load(config_file)
            
            expect(config.models.length).to eq(2)
            expect(config.models[0]["type"]).to eq("default")
            expect(config.models[1]["type"]).to eq("lite")
            expect(config.models[1]["api_key"]).to eq("sk-lite")
            expect(config.models[1]["model"]).to eq("claude-haiku-test")
          end
        end
      end
    end

    describe "priority: config file > CLACKY_XXX > ClaudeCode" do
      it "prefers config file over environment variables" do
        with_env(
          "CLACKY_API_KEY" => "sk-env",
          "ANTHROPIC_API_KEY" => "sk-claude"
        ) do
          with_temp_config([{ "model" => "from-file", "api_key" => "sk-file", "type" => "default" }]) do |config_file|
            config = described_class.load(config_file)
            
            expect(config.models.length).to eq(1)
            expect(config.models.first["api_key"]).to eq("sk-file")
          end
        end
      end

      it "prefers CLACKY_XXX over ClaudeCode env vars" do
        with_env(
          "CLACKY_API_KEY" => "sk-clacky",
          "ANTHROPIC_API_KEY" => "sk-claude"
        ) do
          with_temp_config do |config_file|
            FileUtils.rm_f(config_file)
            
            config = described_class.load(config_file)
            
            expect(config.models.first["api_key"]).to eq("sk-clacky")
          end
        end
      end

      # it "falls back to ClaudeCode if CLACKY_XXX not set" do
      #   with_env("ANTHROPIC_API_KEY" => "sk-claude") do
      #     with_temp_config do |config_file|
      #       FileUtils.rm_f(config_file)
      #
      #       config = described_class.load(config_file)
      #
      #       expect(config.models.first["api_key"]).to eq("sk-claude")
      #       expect(config.models.first["type"]).to eq("default")
      #     end
      #   end
      # end
    end
  end

  # Helper to set environment variables temporarily
  def with_env(vars)
    old_values = {}
    vars.each do |key, value|
      old_values[key] = ENV[key]
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    old_values.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
