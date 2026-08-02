# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"
require_relative "http_server_spec"

RSpec.describe Clacky::Server::HttpServer, "extension marketplace install API" do
  include HttpServerSpecHelpers

  let(:tmpdir) { Dir.mktmpdir("clacky_extension_install_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }
  let(:agent_config) do
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    Clacky::AgentConfig.new(models: [])
  end

  after { FileUtils.rm_rf(tmpdir) }

  it "refreshes an expired download URL and retries one transient 404" do
    brand = instance_double(Clacky::BrandConfig)
    allow(brand).to receive(:extension_detail!).with("demo-extension").and_return(
      {
        success: true,
        extension: {
          "name" => "demo-extension",
          "download_url" => "https://example.com/expired.zip"
        }
      },
      {
        success: true,
        extension: {
          "name" => "demo-extension",
          "download_url" => "https://example.com/fresh.zip"
        }
      }
    )
    allow(Clacky::ExtensionPackager).to receive(:install)
      .with("https://example.com/expired.zip", force: true)
      .and_raise(Clacky::ExtensionPackager::Error, "failed to download: 404 Not Found")
    allow(Clacky::ExtensionPackager).to receive(:install)
      .with("https://example.com/fresh.zip", force: true)
      .and_return(true)
    allow(Clacky::ExtensionLoader).to receive(:invalidate_cache!)
    allow(Clacky::Telemetry).to receive(:extension_install!)

    with_server(agent_config: agent_config) do |server|
      allow(Clacky::BrandConfig).to receive(:load).and_return(brand)
      req = fake_req(
        method: "POST",
        path: "/api/store/extension/install",
        body: { id: "demo-extension", source: "marketplace" }
      )
      res = fake_res
      dispatch(server, req, res)

      expect(res.status).to eq(200)
      expect(parsed_body(res)).to include("ok" => true, "name" => "demo-extension")
      expect(brand).to have_received(:extension_detail!).twice
    end
  end
end
