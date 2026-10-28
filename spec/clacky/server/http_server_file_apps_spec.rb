# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer, "app discovery for extension-less files" do
  include HttpServerSpecHelpers

  let(:tmpdir) { Dir.mktmpdir("clacky_file_apps_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }
  let(:dockerfile) { File.join(tmpdir, "Dockerfile") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      { "model" => "test-model", "api_key" => "k",
        "base_url" => "https://example.invalid/v1", "type" => "default" }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  before { File.write(dockerfile, "FROM ruby\n") }
  after { FileUtils.rm_rf(tmpdir) }

  it "lists plain-text apps because the file declares no document type" do
    apps = [{ "name" => "Visual Studio Code", "path" => "/Applications/Visual Studio Code.app" }]
    expect(Clacky::Utils::MacAppDetector).to receive(:apps_for_ext).with("txt").and_return(apps)

    with_server(agent_config: agent_config) do |server|
      req = fake_req(method: "GET", path: "/api/file/apps", query_string: "path=#{CGI.escape(dockerfile)}")
      res = fake_res
      dispatch(server, req, res)

      expect(res.status).to eq(200)
      expect(parsed_body(res)["apps"]).to eq(apps)
    end
  end
end
