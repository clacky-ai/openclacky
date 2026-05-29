# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

# Reuse helpers from the main http_server spec
require_relative "http_server_spec"

RSpec.describe Clacky::Server::HttpServer, "MCP routes" do
  include HttpServerSpecHelpers

  let(:fake_server_path) { File.expand_path("../../../support/fake_mcp_server.rb", __FILE__) }
  let(:home) { Dir.mktmpdir }
  let(:tmpdir) { Dir.mktmpdir("clacky_http_mcp_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }

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

  before do
    FileUtils.mkdir_p(File.join(home, ".clacky"))
    stub_const("ENV", ENV.to_hash.merge("HOME" => home))
    allow(Dir).to receive(:home).and_return(home)
  end

  after do
    FileUtils.rm_rf(home)
    FileUtils.rm_rf(tmpdir)
  end

  def write_mcp_config(servers)
    File.write(File.join(home, ".clacky", "mcp.json"), JSON.dump("mcpServers" => servers))
  end

  def fake_server_spec
    {
      "fake" => {
        "command" => "ruby",
        "args" => [fake_server_path],
        "description" => "Fake echo+add server.",
      },
    }
  end

  describe "GET /api/mcp/:name/tools" do
    it "404s when the server is not configured in mcp.json" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "GET", path: "/api/mcp/missing/tools")
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(404)
        expect(parsed_body(res)).to include("ok" => false)
      end
    end

    it "returns the live tool list for a configured server" do
      write_mcp_config(fake_server_spec)
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "GET", path: "/api/mcp/fake/tools")
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body["ok"]).to eq(true)
        expect(body["name"]).to eq("fake")
        names = body["tools"].map { |t| t["name"] }
        expect(names).to include("echo", "add")
        body["tools"].each do |t|
          expect(t).to include("description", "input_schema")
        end
      ensure
        server.instance_variable_get(:@mcp_registry)&.shutdown
      end
    end
  end

  describe "POST /api/mcp/:name/call" do
    it "404s when the server is not configured" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/mcp/missing/call", body: { tool: "x" })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(404)
      end
    end

    it "400s when the body is missing the tool field" do
      write_mcp_config(fake_server_spec)
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/mcp/fake/call", body: { arguments: {} })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(400)
      ensure
        server.instance_variable_get(:@mcp_registry)&.shutdown
      end
    end

    it "forwards a tools/call to the live server and returns the raw result" do
      write_mcp_config(fake_server_spec)
      with_server(agent_config: agent_config) do |server|
        req = fake_req(
          method: "POST",
          path:   "/api/mcp/fake/call",
          body:   { tool: "echo", arguments: { message: "hi" } }
        )
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body["ok"]).to eq(true)
        expect(body.dig("result", "content", 0, "text")).to eq("echo: hi")
      ensure
        server.instance_variable_get(:@mcp_registry)&.shutdown
      end
    end
  end

  describe "GET /api/mcp" do
    it "lists configured servers including disabled ones" do
      write_mcp_config(
        "alive" => { "command" => "echo", "args" => ["hi"] },
        "muted" => { "command" => "echo", "args" => ["off"], "disabled" => true }
      )
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "GET", path: "/api/mcp")
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body["servers"].map { |s| [s["name"], s["disabled"]] })
          .to contain_exactly(["alive", false], ["muted", true])
      end
    end

    it "reports an http server's url and type" do
      write_mcp_config("remote" => { "type" => "http", "url" => "https://example.com/mcp" })
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "GET", path: "/api/mcp")
        res = fake_res
        dispatch(server, req, res)
        body = parsed_body(res)
        srv = body["servers"].first
        expect(srv["type"]).to eq("http")
        expect(srv["url"]).to eq("https://example.com/mcp")
      end
    end
  end

  describe "PATCH /api/mcp/:name/enabled" do
    def patch_req(name, body)
      req = fake_req(method: "PATCH", path: "/api/mcp/#{name}/enabled", body: body)
      allow(req).to receive(:peeraddr).and_return(["AF_INET", 0, "127.0.0.1", "127.0.0.1"])
      req
    end

    it "404s when the server is not configured" do
      with_server(agent_config: agent_config) do |server|
        req = patch_req("ghost", { enabled: false })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(404)
      end
    end

    it "400s when enabled is missing" do
      write_mcp_config("foo" => { "command" => "echo" })
      with_server(agent_config: agent_config) do |server|
        req = patch_req("foo", {})
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(400)
      end
    end

    it "writes disabled:true and removes it on toggle back" do
      write_mcp_config("foo" => { "command" => "echo" })
      with_server(agent_config: agent_config) do |server|
        req = patch_req("foo", { enabled: false })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(200)
        data = JSON.parse(File.read(File.join(home, ".clacky", "mcp.json")))
        expect(data["mcpServers"]["foo"]["disabled"]).to eq(true)

        req2 = patch_req("foo", { enabled: true })
        res2 = fake_res
        dispatch(server, req2, res2)
        expect(res2.status).to eq(200)
        data2 = JSON.parse(File.read(File.join(home, ".clacky", "mcp.json")))
        expect(data2["mcpServers"]["foo"]).not_to have_key("disabled")
      end
    end
  end
end
