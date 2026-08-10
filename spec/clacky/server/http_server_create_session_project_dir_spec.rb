# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"
require_relative "../../support/http_server_spec_helpers"

# Regression spec for issue #467: sessions created while a project is
# selected must land in the project's working directory, not silently fall
# back to the global default. The New Session panel used to prefill its
# "working directory" field with the global default even when a project was
# remembered from localStorage, so the client always sent a working_dir and
# the backend's project-dir inheritance (which only triggers when
# working_dir is absent) never ran. These specs lock down the backend half
# of that contract.
RSpec.describe Clacky::Server::HttpServer, "POST /api/sessions with a project" do
  include HttpServerSpecHelpers

  let(:tmproot)     { Dir.mktmpdir("clacky_proj_dir_spec") }
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

  def create_project(server, working_dir:)
    server.instance_variable_get(:@project_manager)
          .create(name: "proj", working_dir: working_dir)
  end

  def create_session(server, body)
    res = fake_res
    dispatch(server, fake_req(method: "POST", path: "/api/sessions", body: body), res)
    [res.status, parsed_body(res)]
  end

  it "inherits the project's working_dir when the client sends none" do
    with_server(agent_config: agent_config) do |server|
      project_dir = File.join(tmproot, "proj_ws")
      project = create_project(server, working_dir: project_dir)

      status, body = create_session(server, { name: "s1", project_id: project[:id] })

      expect(status).to eq(201)
      expect(body["session"]["working_dir"]).to eq(project_dir)
    end
  end

  it "keeps an explicit working_dir over the project's" do
    with_server(agent_config: agent_config) do |server|
      explicit_dir = File.join(tmproot, "explicit")
      project = create_project(server, working_dir: File.join(tmproot, "proj_ws"))

      status, body = create_session(server,
        { name: "s2", project_id: project[:id], working_dir: explicit_dir })

      expect(status).to eq(201)
      expect(body["session"]["working_dir"]).to eq(explicit_dir)
    end
  end

  it "falls back to the default working dir when the project has none" do
    with_server(agent_config: agent_config) do |server|
      custom_default = File.join(tmproot, "default_ws")
      FileUtils.mkdir_p(custom_default)
      allow(server).to receive(:default_working_dir).and_return(custom_default)
      project = create_project(server, working_dir: nil)

      status, body = create_session(server, { name: "s3", project_id: project[:id] })

      expect(status).to eq(201)
      expect(body["session"]["working_dir"]).to eq(custom_default)
    end
  end
end
