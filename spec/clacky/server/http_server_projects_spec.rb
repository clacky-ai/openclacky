# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"
require_relative "http_server_spec"

RSpec.describe Clacky::Server::HttpServer, "projects API" do
  include HttpServerSpecHelpers

  let(:tmproot) { Dir.mktmpdir("clacky_projects_api") }
  let(:config_file) { File.join(tmproot, "config.yml") }
  let(:projects_file) { File.join(tmproot, "projects.json") }
  let(:project_dir) { File.join(tmproot, "demo-app") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      {
        "model" => "test-model",
        "api_key" => "sk-testkey1234567890abcd",
        "base_url" => "https://api.example.com",
        "anthropic_format" => true,
        "type" => "default"
      }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  before { FileUtils.mkdir_p(project_dir) }
  after { FileUtils.rm_rf(tmproot) }

  def with_projects_server
    with_server(agent_config: agent_config) do |server|
      server.instance_variable_set(:@project_manager, Clacky::ProjectManager.new(file_path: projects_file))
      yield server
    end
  end

  it "lists empty projects initially" do
    with_projects_server do |server|
      req = fake_req(method: "GET", path: "/api/projects")
      res = fake_res
      dispatch(server, req, res)

      expect(res.status).to eq(200)
      body = parsed_body(res)
      expect(body["projects"]).to eq([])
    end
  end

  it "opens a project path and returns it in the list" do
    with_projects_server do |server|
      req = fake_req(method: "POST", path: "/api/projects", body: { path: project_dir, name: "Demo" })
      res = fake_res
      dispatch(server, req, res)

      expect(res.status).to eq(200)
      project = parsed_body(res)["project"]
      expect(project["name"]).to eq("Demo")
      expect(project["path"]).to eq(File.realpath(project_dir))

      list_res = fake_res
      dispatch(server, fake_req(method: "GET", path: "/api/projects"), list_res)
      expect(parsed_body(list_res)["projects"].map { |p| p["id"] }).to eq([project["id"]])
    end
  end

  it "renames, touches, and deletes a project" do
    with_projects_server do |server|
      create_res = fake_res
      dispatch(server, fake_req(method: "POST", path: "/api/projects", body: { path: project_dir }), create_res)
      project = parsed_body(create_res)["project"]
      id = project["id"]

      rename_res = fake_res
      dispatch(server, fake_req(method: "PATCH", path: "/api/projects/#{id}", body: { name: "New Name" }), rename_res)
      expect(rename_res.status).to eq(200)
      expect(parsed_body(rename_res)["project"]["name"]).to eq("New Name")

      touch_res = fake_res
      dispatch(server, fake_req(method: "POST", path: "/api/projects/#{id}/touch"), touch_res)
      expect(touch_res.status).to eq(200)
      expect(parsed_body(touch_res)["project"]["id"]).to eq(id)

      delete_res = fake_res
      dispatch(server, fake_req(method: "DELETE", path: "/api/projects/#{id}"), delete_res)
      expect(delete_res.status).to eq(200)
      expect(parsed_body(delete_res)["ok"]).to be true

      list_res = fake_res
      dispatch(server, fake_req(method: "GET", path: "/api/projects"), list_res)
      expect(parsed_body(list_res)["projects"]).to eq([])
      expect(Dir.exist?(project_dir)).to be true
    end
  end

  it "rejects opening a missing directory" do
    with_projects_server do |server|
      req = fake_req(method: "POST", path: "/api/projects", body: { path: File.join(tmproot, "nope") })
      res = fake_res
      dispatch(server, req, res)
      expect(res.status).to eq(422)
    end
  end
end
