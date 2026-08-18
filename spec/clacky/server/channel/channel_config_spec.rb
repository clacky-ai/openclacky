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

  describe "#set_status_messages" do
    it "persists the flag as a boolean" do
      config = described_class.new(channels: { "feishu" => { "app_id" => "cli_x" } })
      config.set_status_messages(false)
      expect(config.status_messages_enabled?).to be false
      expect(config.instance_variable_get(:@channels)["feishu"]["app_id"]).to eq("cli_x")
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
        expect(data["channels"]["feishu"]["enabled"]).to be true
      end
    end

    it "does not touch channel credentials" do
      config = described_class.new(channels: { "feishu" => { "enabled" => false } })
      config.set_status_messages(true)
      expect(config.enabled?(:feishu)).to be false
      expect(config.status_messages_enabled?).to be true
    end
  end

  describe "#deep_copy" do
    it "copies the global flag independently of the original" do
      config = described_class.new(channels: {}, status_messages: false)
      copy   = config.deep_copy
      copy.set_status_messages(true)
      expect(config.status_messages_enabled?).to be false
      expect(copy.status_messages_enabled?).to be true
    end
  end
end
