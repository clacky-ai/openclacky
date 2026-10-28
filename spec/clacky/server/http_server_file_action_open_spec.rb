# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer, "POST /api/file-action open" do
  include HttpServerSpecHelpers

  let(:tmpdir) { Dir.mktmpdir("clacky_file_action_open_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }
  let(:file_path) { File.join(tmpdir, "view.js") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      { "model" => "test-model", "api_key" => "k",
        "base_url" => "https://example.invalid/v1", "type" => "default" }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  before { File.write(file_path, "console.log(1)\n") }
  after { FileUtils.rm_rf(tmpdir) }

  def request_open(server)
    req = fake_req(
      method: "POST",
      path:   "/api/file-action",
      body:   { "path" => file_path, "action" => "open" }
    )
    res = fake_res
    dispatch(server, req, res)
    res
  end

  it "returns 200 when the launcher succeeds" do
    allow(Clacky::Utils::EnvironmentDetector).to receive(:open_file).with(file_path).and_return(true)

    with_server(agent_config: agent_config) do |server|
      res = request_open(server)
      expect(res.status).to eq(200)
      expect(parsed_body(res)["ok"]).to be(true)
    end
  end

  it "returns 500 when the launcher fails" do
    allow(Clacky::Utils::EnvironmentDetector).to receive(:open_file).with(file_path).and_return(false)

    with_server(agent_config: agent_config) do |server|
      res = request_open(server)
      expect(res.status).to eq(500)
      expect(parsed_body(res)["error"]).to eq("failed to open file")
    end
  end

  it "returns 501 on an unsupported OS" do
    allow(Clacky::Utils::EnvironmentDetector).to receive(:open_file).with(file_path).and_return(nil)

    with_server(agent_config: agent_config) do |server|
      res = request_open(server)
      expect(res.status).to eq(501)
      expect(parsed_body(res)["error"]).to eq("unsupported OS")
    end
  end
end
