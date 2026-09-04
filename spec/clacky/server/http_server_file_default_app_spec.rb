# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer, "GET /api/file/default-app" do
  include HttpServerSpecHelpers

  let(:tmpdir) { File.join(Dir.mktmpdir("clacky_default_app_spec")) }
  let(:config_file) { File.join(tmpdir, "config.yml") }
  let(:file_path) { File.join(tmpdir, "notes.md") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      { "model" => "test-model", "api_key" => "k",
        "base_url" => "https://example.invalid/v1", "type" => "default" }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  before { File.binwrite(file_path, "# hi") }
  after { FileUtils.rm_rf(tmpdir) }

  def request_default_app(server, path)
    req = fake_req(
      method:        "GET",
      path:          "/api/file/default-app",
      query_string:  "path=#{URI.encode_www_form_component(path)}"
    )
    res = fake_res
    dispatch(server, req, res)
    res
  end

  it "returns the default app bundle" do
    app = { "name" => "Xcode", "path" => "/Applications/Xcode.app" }
    allow(Clacky::Utils::MacAppDetector)
      .to receive(:default_app_for).with(file_path).and_return(app)

    with_server(agent_config: agent_config) do |server|
      res = request_default_app(server, file_path)
      expect(res.status).to eq(200)
      body = parsed_body(res)
      expect(body["ok"]).to be(true)
      expect(body["app"]).to eq(app)
    end
  end

  it "returns a null app when no extension" do
    extless = File.join(tmpdir, "Makefile")
    File.binwrite(extless, "all:")

    with_server(agent_config: agent_config) do |server|
      res = request_default_app(server, extless)
      expect(res.status).to eq(200)
      expect(parsed_body(res)["app"]).to be_nil
    end
  end

  it "returns 400 when path is missing" do
    with_server(agent_config: agent_config) do |server|
      res = request_default_app(server, "")
      expect(res.status).to eq(400)
    end
  end
end
