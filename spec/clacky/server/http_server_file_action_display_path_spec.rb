# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

require_relative "http_server_spec"

RSpec.describe Clacky::Server::HttpServer, "POST /api/file-action display-path" do
  include HttpServerSpecHelpers

  let(:tmpdir) { Dir.mktmpdir("clacky_file_action_display_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }
  let(:file_path) { File.join(tmpdir, "cat.png") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      { "model" => "test-model", "api_key" => "k",
        "base_url" => "https://example.invalid/v1", "type" => "default" }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  before { File.binwrite(file_path, "PNG") }
  after { FileUtils.rm_rf(tmpdir) }

  def request_display_path(server)
    req = fake_req(
      method: "POST",
      path:   "/api/file-action",
      body:   { "path" => file_path, "action" => "display-path" }
    )
    res = fake_res
    dispatch(server, req, res)
    res
  end

  it "returns the Windows UNC path on WSL" do
    unc = "\\\\wsl.localhost\\Ubuntu#{file_path}"
    allow(Clacky::Utils::EnvironmentDetector)
      .to receive(:linux_to_win_path).with(file_path).and_return(unc)

    with_server(agent_config: agent_config) do |server|
      res = request_display_path(server)
      expect(res.status).to eq(200)
      body = parsed_body(res)
      expect(body["ok"]).to be(true)
      expect(body["path"]).to eq(unc)
    end
  end

  it "returns the original Linux path on non-WSL (no-op)" do
    with_server(agent_config: agent_config) do |server|
      res = request_display_path(server)
      expect(res.status).to eq(200)
      body = parsed_body(res)
      expect(body["ok"]).to be(true)
      expect(body["path"]).to eq(file_path)
    end
  end

  it "returns 404 for a missing file" do
    req = fake_req(
      method: "POST",
      path:   "/api/file-action",
      body:   { "path" => File.join(tmpdir, "missing.png"), "action" => "display-path" }
    )
    res = fake_res
    with_server(agent_config: agent_config) do |server|
      dispatch(server, req, res)
      expect(res.status).to eq(404)
    end
  end
end
