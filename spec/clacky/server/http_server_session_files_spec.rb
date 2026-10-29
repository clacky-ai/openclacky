# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"
require_relative "../../support/http_server_spec_helpers"

# The file tree needs to tell "this folder was deleted" apart from a generic
# failure so the UI can explain it and offer the folder picker. That distinction
# rides on the `code` field of the error payload.
RSpec.describe Clacky::Server::HttpServer, "GET /api/sessions/:id/files errors" do
  include HttpServerSpecHelpers

  let(:tmproot)     { Dir.mktmpdir("clacky_session_files_spec") }
  let(:config_file) { File.join(tmproot, "config.yml") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      {
        "model"            => "test-model",
        "api_key"          => "sk-testkey1234567890abcd",
        "base_url"         => "https://api.example.com",
        "anthropic_format" => true,
        "type"             => "default"
      }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  after { FileUtils.rm_rf(tmproot) }

  def stub_session(server, working_dir:)
    agent    = double("agent", working_dir: working_dir)
    registry = double("registry", ensure: true, get: { agent: agent })
    server.instance_variable_set(:@registry, registry)
  end

  def list_files(server, query_string)
    req = fake_req(method: "GET", path: "/api/sessions/s1/files", query_string: query_string)
    res = fake_res
    dispatch(server, req, res)
    res
  end

  it "flags a deleted working directory with a code the client can act on" do
    with_server(agent_config: agent_config) do |server|
      missing = File.join(tmproot, "removed_workspace")
      stub_session(server, working_dir: missing)

      res = list_files(server, "path=")

      expect(res.status).to eq(404)
      body = parsed_body(res)
      expect(body["code"]).to eq("working_dir_missing")
      expect(body["path"]).to eq(missing)
    end
  end

  it "flags a deleted subdirectory separately from a missing working directory" do
    with_server(agent_config: agent_config) do |server|
      root = File.join(tmproot, "ws")
      FileUtils.mkdir_p(root)
      stub_session(server, working_dir: root)

      res = list_files(server, "path=gone")

      expect(res.status).to eq(404)
      expect(parsed_body(res)["code"]).to eq("directory_missing")
    end
  end

  it "still lists an existing directory" do
    with_server(agent_config: agent_config) do |server|
      root = File.join(tmproot, "ws")
      FileUtils.mkdir_p(File.join(root, "nested"))
      File.write(File.join(root, "note.md"), "hi")
      stub_session(server, working_dir: root)

      res = list_files(server, "path=")

      expect(res.status).to eq(200)
      body = parsed_body(res)
      expect(body["entries"].map { |e| [e["name"], e["type"]] })
        .to eq([["nested", "dir"], ["note.md", "file"]])
    end
  end
end
