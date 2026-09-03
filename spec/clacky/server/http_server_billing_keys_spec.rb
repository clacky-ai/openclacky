# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "clacky/billing/platform_billing"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "billing multi-key platform source" do
  let(:tmpdir) { Dir.mktmpdir("clacky_billing_keys_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }
  let(:models) do
    [
      { "api_key" => "clacky-a", "base_url" => "https://api.openclacky.com", "model" => "dsk-deepseek-v4-pro" },
      { "api_key" => "clacky-b", "base_url" => "https://api.openclacky.com", "model" => "or-gemini-3-1-pro" },
      { "api_key" => "sk-ant-123", "base_url" => "https://api.anthropic.com", "model" => "claude-sonnet-4-5" }
    ]
  end
  let(:agent_config) { Clacky::AgentConfig.new(models: models) }
  let(:server) do
    described_class.new(
      host: "127.0.0.1",
      port: 0,
      agent_config: agent_config,
      client_factory: -> { double("client") },
      sessions_dir: File.join(tmpdir, "sessions"),
      master_pid: 12_345
    )
  end

  before do
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "#platform_api_keys" do
    it "collects every openclacky key and ignores other providers" do
      expect(server.send(:platform_api_keys)).to eq(["clacky-a", "clacky-b"])
    end

    it "dedupes repeated keys and drops empty ones" do
      models << { "api_key" => "clacky-a", "base_url" => "https://api.openclacky.com", "model" => "or-veo-3" }
      models << { "api_key" => "  ", "base_url" => "https://api.openclacky.com", "model" => "or-veo-3-fast" }

      expect(server.send(:platform_api_keys)).to eq(["clacky-a", "clacky-b"])
    end

    it "returns an empty array when no openclacky model is configured" do
      models.replace([
                       { "api_key" => "sk-ant-123", "base_url" => "https://api.anthropic.com", "model" => "claude-sonnet-4-5" }
                     ])

      expect(server.send(:platform_api_keys)).to eq([])
    end
  end

  describe "#platform_usage_summary" do
    it "queries the platform with all openclacky keys" do
      allow(Clacky::Billing::PlatformBilling).to receive(:fetch_summary_merged).and_return(nil)

      server.send(:platform_usage_summary, period: "month", model: nil)

      expect(Clacky::Billing::PlatformBilling).to have_received(:fetch_summary_merged)
        .with(["clacky-a", "clacky-b"], period: "month", model: nil)
    end

    it "translates the alias model filter to its real id" do
      allow(Clacky::Billing::PlatformBilling).to receive(:fetch_summary_merged).and_return(nil)

      server.send(:platform_usage_summary, period: "month", model: "dsk-deepseek-v4-pro")

      expect(Clacky::Billing::PlatformBilling).to have_received(:fetch_summary_merged)
        .with(["clacky-a", "clacky-b"], period: "month", model: "deepseek-v4-pro")
    end

    it "returns nil without querying when no openclacky key is configured" do
      models.replace([
                       { "api_key" => "sk-ant-123", "base_url" => "https://api.anthropic.com", "model" => "claude-sonnet-4-5" }
                     ])
      allow(Clacky::Billing::PlatformBilling).to receive(:fetch_summary_merged)

      expect(server.send(:platform_usage_summary, period: "month", model: nil)).to be_nil
      expect(Clacky::Billing::PlatformBilling).not_to have_received(:fetch_summary_merged)
    end
  end

  describe "#platform_usage_daily" do
    it "queries the platform with all openclacky keys" do
      allow(Clacky::Billing::PlatformBilling).to receive(:fetch_daily_merged).and_return(nil)

      server.send(:platform_usage_daily, days: 30, model: nil)

      expect(Clacky::Billing::PlatformBilling).to have_received(:fetch_daily_merged)
        .with(["clacky-a", "clacky-b"], days: 30, model: nil)
    end
  end
end
