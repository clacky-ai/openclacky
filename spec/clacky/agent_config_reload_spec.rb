# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Clacky::AgentConfig#reload!" do
  let(:tmpdir)     { Dir.mktmpdir }
  let(:config_file) { File.join(tmpdir, "config.yml") }

  after { FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir) }

  def write_config(models, settings = {}, runtime_models = nil)
    data = { "settings" => settings, "models" => models }
    data["runtime_models"] = runtime_models unless runtime_models.nil?
    File.write(config_file, YAML.dump(data))
  end

  let(:initial_models) do
    [
      { "model" => "claude-sonnet-4-5", "base_url" => "https://a.example", "api_key" => "old-key", "type" => "default" },
      { "model" => "gpt-5", "base_url" => "https://b.example", "api_key" => "k2" }
    ]
  end

  it "picks up an api_key rotated on disk" do
    write_config(initial_models)
    config = Clacky::AgentConfig.load(config_file)

    updated = Marshal.load(Marshal.dump(initial_models))
    updated[0]["api_key"] = "new-key"
    write_config(updated)

    expect(config.reload!(config_file)).to be true
    expect(config.current_model["api_key"]).to eq("new-key")
  end

  it "keeps the same @models array object so existing sessions see the change" do
    write_config(initial_models)
    config = Clacky::AgentConfig.load(config_file)
    session = config.deep_copy

    expect(session.models).to be(config.models)

    write_config(initial_models + [{ "model" => "kimi-k2", "base_url" => "https://c.example", "api_key" => "k3" }])
    config.reload!(config_file)

    expect(session.models).to be(config.models)
    expect(session.models.size).to eq(3)
    expect(session.models.map { |m| m["model"] }).to include("kimi-k2")
  end

  it "preserves model ids so a session's current_model_id keeps resolving" do
    write_config(initial_models)
    config = Clacky::AgentConfig.load(config_file)

    session = config.deep_copy
    gpt5 = config.models.find { |m| m["model"] == "gpt-5" }
    session.current_model_id = gpt5["id"]
    original_id = gpt5["id"]

    config.reload!(config_file)

    expect(config.models.find { |m| m["model"] == "gpt-5" }["id"]).to eq(original_id)
    expect(session.current_model).not_to be_nil
    expect(session.current_model["model"]).to eq("gpt-5")
  end

  it "preserves runtime model identity by runtime_id and provider_id" do
    runtime_models = [
      {
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "Codex default",
        "type" => "default"
      }
    ]
    write_config([], {}, runtime_models)
    config = Clacky::AgentConfig.load(config_file)
    original_id = config.current_model["id"]

    updated = Marshal.load(Marshal.dump(runtime_models))
    updated.first["remark"] = "renamed"
    write_config([], {}, updated)

    expect(config.reload!(config_file)).to be true
    expect(config.current_model["id"]).to eq(original_id)
    expect(config.current_model["remark"]).to eq("renamed")
  end

  it "does not collapse distinct credentialless runtime cards onto the same id" do
    runtime_models = [
      {
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "Codex default",
        "type" => "default"
      },
      {
        "provider_id" => "other-agent",
        "runtime_id" => "other-runtime",
        "display_model" => "Other runtime"
      }
    ]
    write_config([], {}, runtime_models)
    config = Clacky::AgentConfig.load(config_file)
    original_ids = config.models.each_with_object({}) do |model, result|
      result[[model["runtime_id"], model["provider_id"]]] = model["id"]
    end

    write_config([], {}, runtime_models.reverse)

    expect(config.reload!(config_file)).to be true
    expect(config.models.map { |model| model["id"] }.uniq.length).to eq(2)
    config.models.each do |model|
      identity = [model["runtime_id"], model["provider_id"]]
      expect(model["id"]).to eq(original_ids[identity])
    end
  end

  it "keeps duplicate legacy runtime cards on distinct ids during reload" do
    runtime_models = [
      {
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "Codex default",
        "type" => "default",
        "remark" => "first"
      },
      {
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "Codex default",
        "remark" => "second"
      }
    ]
    write_config([], {}, runtime_models)
    config = Clacky::AgentConfig.load(config_file)
    original_ids = config.models.map { |model| model["id"] }

    write_config([], {}, runtime_models)

    expect(config.reload!(config_file)).to be true
    expect(config.models.map { |model| model["id"] }).to eq(original_ids)
    expect(config.models.map { |model| model["id"] }.uniq.length).to eq(2)
  end

  it "falls back to the default model when the pinned model was deleted" do
    write_config(initial_models)
    config = Clacky::AgentConfig.load(config_file)
    config.current_model_id = config.models.find { |m| m["model"] == "gpt-5" }["id"]

    write_config([initial_models[0]])
    config.reload!(config_file)

    expect(config.current_model["model"]).to eq("claude-sonnet-4-5")
  end

  it "applies changed settings" do
    write_config(initial_models, "compression_threshold" => 150_000)
    config = Clacky::AgentConfig.load(config_file)
    expect(config.compression_threshold).to eq(150_000)

    write_config(initial_models, "compression_threshold" => 64_000)
    config.reload!(config_file)

    expect(config.compression_threshold).to eq(64_000)
  end

  it "transitions from unconfigured to configured" do
    write_config([])
    config = Clacky::AgentConfig.load(config_file)

    with_env("CLACKY_API_KEY" => "", "ANTHROPIC_API_KEY" => "", "ANTHROPIC_AUTH_TOKEN" => "") do
      expect(config.models_configured?).to be false

      write_config(initial_models)
      config.reload!(config_file)
    end

    expect(config.models_configured?).to be true
  end

  it "keeps the in-memory config when the file is corrupt" do
    write_config(initial_models)
    config = Clacky::AgentConfig.load(config_file)

    File.write(config_file, "models:\n  - [unclosed\n")

    expect(config.reload!(config_file)).to be false
    expect(config.models.size).to eq(2)
    expect(config.current_model["api_key"]).to eq("old-key")
  end
end
