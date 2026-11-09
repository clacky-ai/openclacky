# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"
require "tmpdir"
require "fileutils"

RSpec.describe Clacky::ChannelConfig do
  def with_temp_channels_file
    tmp_dir      = Dir.mktmpdir
    channels_yml = File.join(tmp_dir, "channels.yml")
    stub_const("Clacky::ChannelConfig::CONFIG_DIR", tmp_dir)
    stub_const("Clacky::ChannelConfig::CONFIG_FILE", channels_yml)
    yield channels_yml
  ensure
    FileUtils.rm_rf(tmp_dir)
  end

  describe "#status_messages_enabled?" do
    it "defaults to false" do
      config = described_class.new(channels: {})
      expect(config.status_messages_enabled?).to be false
    end

    it "defaults to false when the field is missing" do
      config = described_class.new(channels: { "feishu" => { "enabled" => true } })
      expect(config.status_messages_enabled?).to be false
    end

    it "returns true when explicitly enabled" do
      config = described_class.new(channels: {}, status_messages: true)
      expect(config.status_messages_enabled?).to be true
    end

    it "applies across all platforms" do
      config = described_class.new(channels: { "feishu" => { "enabled" => true }, "telegram" => {} }, status_messages: false)
      expect(config.status_messages_enabled?).to be false
    end
  end

  describe "#process_messages_enabled?" do
    it "defaults to false" do
      config = described_class.new(channels: {})
      expect(config.process_messages_enabled?).to be false
    end

    it "returns true when explicitly enabled" do
      config = described_class.new(channels: {}, process_messages: true)
      expect(config.process_messages_enabled?).to be true
    end
  end

  describe "#set_status_messages" do
    it "persists the flag as a boolean" do
      config = described_class.new(channels: { "feishu" => { "app_id" => "cli_x" } })
      config.set_status_messages(false)
      expect(config.status_messages_enabled?).to be false
      expect(config.instance(:feishu, "default")["app_id"]).to eq("cli_x")
    end

    it "round-trips through save/load" do
      with_temp_channels_file do |file|
        config = described_class.new(channels: { "feishu" => { "enabled" => true } })
        config.set_status_messages(false)
        config.save(file)

        reloaded = described_class.load(file)
        expect(reloaded.status_messages_enabled?).to be false
      end
    end

    it "round-trips an enabled flag through save/load" do
      with_temp_channels_file do |file|
        config = described_class.new(channels: { "feishu" => { "enabled" => true } })
        config.set_status_messages(true)
        config.save(file)

        reloaded = described_class.load(file)
        expect(reloaded.status_messages_enabled?).to be true
      end
    end

    it "writes the flag as a top-level YAML key" do
      with_temp_channels_file do |file|
        config = described_class.new(channels: { "feishu" => { "enabled" => true } })
        config.set_status_messages(false)
        config.save(file)

        raw = File.read(file)
        expect(raw).to start_with("---")
        data = YAMLCompat.safe_load(raw, permitted_classes: [Symbol])
        expect(data["status_messages"]).to be false
        expect(data["channels"]["feishu"].first["enabled"]).to be true
      end
    end

    it "does not touch channel credentials" do
      config = described_class.new(channels: { "feishu" => { "enabled" => false } })
      config.set_status_messages(true)
      expect(config.enabled?(:feishu)).to be false
      expect(config.status_messages_enabled?).to be true
    end
  end

  describe "#set_process_messages" do
    it "round-trips through save/load" do
      with_temp_channels_file do |file|
        config = described_class.new(channels: { "feishu" => { "enabled" => true } })
        config.set_process_messages(true)
        config.save(file)

        reloaded = described_class.load(file)
        expect(reloaded.process_messages_enabled?).to be true
      end
    end
  end

  describe "#progress_cards_enabled?" do
    it "defaults to true" do
      expect(described_class.new(channels: {}).progress_cards_enabled?).to be true
    end

    it "stays on for existing configs that never set the key" do
      with_temp_channels_file do |file|
        File.write(file, YAML.dump({ "status_messages" => true, "channels" => {} }))
        expect(described_class.load(file).progress_cards_enabled?).to be true
      end
    end

    it "is false only when explicitly set to false" do
      expect(described_class.new(channels: {}, progress_cards: false).progress_cards_enabled?).to be false
      expect(described_class.new(channels: {}, progress_cards: nil).progress_cards_enabled?).to be true
    end
  end

  describe "#set_progress_cards" do
    it "round-trips false through save/load" do
      with_temp_channels_file do |file|
        config = described_class.new(channels: { "feishu" => { "enabled" => true } })
        config.set_progress_cards(false)
        config.save(file)

        expect(YAML.safe_load(File.read(file))["progress_cards"]).to be false
        expect(described_class.load(file).progress_cards_enabled?).to be false
      end
    end
  end

  describe "multiple instances" do
    it "migrates a legacy single-hash entry to one instance with id default" do
      config = described_class.new(channels: { "feishu" => { "enabled" => true, "app_id" => "cli_x" } })

      expect(config.instances(:feishu).length).to eq(1)
      expect(config.instance(:feishu)["id"]).to eq("default")
      expect(config.platform_config(:feishu)[:app_id]).to eq("cli_x")
    end

    it "keeps legacy callers working through the first instance" do
      config = described_class.new(channels: {
        "feishu" => [
          { "id" => "default", "enabled" => true, "app_id" => "cli_a" },
          { "id" => "work", "enabled" => false, "app_id" => "cli_b" }
        ]
      })

      expect(config.enabled?(:feishu)).to be true
      expect(config.enabled?(:feishu, "work")).to be false
      expect(config.platform_config(:feishu)[:app_id]).to eq("cli_a")
      expect(config.platform_config(:feishu, "work")[:app_id]).to eq("cli_b")
    end

    it "adds an instance without touching existing credentials" do
      config = described_class.new(channels: { "feishu" => { "enabled" => true, "app_id" => "cli_a" } })

      id = config.set_platform(:feishu, instance_id: "work", name: "Company", app_id: "cli_b", app_secret: "s")

      expect(id).to eq("work")
      expect(config.instance_ids(:feishu)).to eq(%w[default work])
      expect(config.instance(:feishu, "default")["app_id"]).to eq("cli_a")
      expect(config.instance(:feishu, "work")["app_id"]).to eq("cli_b")
      expect(config.instance(:feishu, "work")["name"]).to eq("Company")
      expect(config.instance(:feishu, "work")["enabled"]).to be true
    end

    it "generates a fallback id when none is given for a new platform" do
      config = described_class.new(channels: {})
      expect(config.set_platform(:telegram, bot_token: "t")).to eq("default")

      config = described_class.new(channels: { "telegram" => [
        { "id" => "default", "enabled" => true, "bot_token" => "a" },
        { "id" => "telegram-2", "enabled" => true, "bot_token" => "b" }
      ] })
      expect(config.set_platform(:telegram, bot_token: "c")).to eq("default")
      expect(config.instance(:telegram, "default")["bot_token"]).to eq("c")
    end

    it "enables, disables and removes a single instance" do
      config = described_class.new(channels: {
        "feishu" => [
          { "id" => "default", "enabled" => true, "app_id" => "a" },
          { "id" => "work", "enabled" => true, "app_id" => "b" }
        ]
      })

      config.disable_platform(:feishu, "work")
      expect(config.enabled?(:feishu)).to be true
      expect(config.enabled?(:feishu, "work")).to be false

      config.enable_platform(:feishu, "work")
      expect(config.enabled?(:feishu, "work")).to be true

      expect(config.remove_platform(:feishu, "work")).to be true
      expect(config.instance_ids(:feishu)).to eq(%w[default])
    end

    it "lists enabled instances across platforms" do
      config = described_class.new(channels: {
        "feishu" => [
          { "id" => "default", "enabled" => true },
          { "id" => "work", "enabled" => false }
        ],
        "telegram" => [{ "id" => "default", "enabled" => true }]
      })

      pairs = config.enabled_instances
      expect(pairs.map { |platform, inst| [platform, inst["id"]] })
        .to eq([[:feishu, "default"], [:telegram, "default"]])
      expect(config.enabled_platforms).to eq(%i[feishu telegram])
    end

    it "round-trips multiple instances through save/load" do
      with_temp_channels_file do |file|
        config = described_class.new(channels: {
          "feishu" => [
            { "id" => "default", "enabled" => true, "app_id" => "a" },
            { "id" => "work", "enabled" => false, "name" => "Company", "app_id" => "b" }
          ]
        })
        config.save(file)

        reloaded = described_class.load(file)
        expect(reloaded.instance_ids(:feishu)).to eq(%w[default work])
        expect(reloaded.instance(:feishu, "work")["name"]).to eq("Company")
        expect(reloaded.platform_config(:feishu, "work")[:app_id]).to eq("b")
        expect(reloaded.enabled?(:feishu, "work")).to be false
      end
    end

    it "does not leak meta keys into adapter config" do
      config = described_class.new(channels: {
        "custom" => [{ "id" => "default", "name" => "X", "enabled" => true, "token" => "t" }]
      })
      expect(config.platform_config(:custom)).to eq(token: "t")
    end
  end

  describe "#deep_copy" do
    it "copies the progress cards flag independently of the original" do
      config = described_class.new(channels: {}, progress_cards: false)
      copy   = config.deep_copy
      copy.set_progress_cards(true)
      expect(config.progress_cards_enabled?).to be false
      expect(copy.progress_cards_enabled?).to be true
    end

    it "copies the status flag independently of the original" do
      config = described_class.new(channels: {}, status_messages: false)
      copy   = config.deep_copy
      copy.set_status_messages(true)
      expect(config.status_messages_enabled?).to be false
      expect(copy.status_messages_enabled?).to be true
    end

    it "copies the process flag independently of the original" do
      config = described_class.new(channels: {}, process_messages: false)
      copy   = config.deep_copy
      copy.set_process_messages(true)
      expect(config.process_messages_enabled?).to be false
      expect(copy.process_messages_enabled?).to be true
    end
  end
end
