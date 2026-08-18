# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer, "CORS preflight" do
  include HttpServerSpecHelpers

  let(:tmpdir) { Dir.mktmpdir("clacky_cors_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      { "model" => "test-model", "api_key" => "k",
        "base_url" => "https://example.invalid/v1", "type" => "default" }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  after { FileUtils.rm_rf(tmpdir) }

  # A response double that captures headers set via res["Key"] = value.
  def capturing_res
    res = double("res").as_null_object
    headers = {}
    allow(res).to receive(:status=) { |v| res.instance_variable_set(:@status, v) }
    allow(res).to receive(:body=)   { |v| res.instance_variable_set(:@body, v) }
    allow(res).to receive(:content_type=)
    allow(res).to receive(:[]=)     { |k, v| headers[k] = v }
    allow(res).to receive(:[])      { |k| headers[k] }
    allow(res).to receive(:status)  { res.instance_variable_get(:@status) }
    allow(res).to receive(:body)    { res.instance_variable_get(:@body) }
    res
  end

  def dispatch_options(server, headers: {})
    req = fake_req(method: "OPTIONS", path: "/api/upload", headers: headers)
    res = capturing_res
    dispatch(server, req, res)
    res
  end

  it "returns 204 with CORS allow headers for a cross-origin preflight" do
    with_server(agent_config: agent_config) do |server|
      res = dispatch_options(server, headers: {
        "Origin"                        => "https://app.example.com",
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "content-type,x-lang"
      })
      expect(res.status).to eq(204)
      expect(res["Access-Control-Allow-Origin"]).to eq("https://app.example.com")
      expect(res["Access-Control-Allow-Methods"]).to include("POST")
      expect(res["Access-Control-Allow-Headers"]).to eq("content-type,x-lang")
      expect(res["Access-Control-Max-Age"]).to eq("86400")
    end
  end

  it "defaults to wildcard origin and a sane header set when none are requested" do
    with_server(agent_config: agent_config) do |server|
      res = dispatch_options(server)
      expect(res.status).to eq(204)
      expect(res["Access-Control-Allow-Origin"]).to eq("*")
      expect(res["Access-Control-Allow-Methods"]).to eq("GET, POST, PUT, PATCH, DELETE, OPTIONS")
      expect(res["Access-Control-Allow-Headers"]).to include("X-Lang", "Authorization")
    end
  end

  it "passes preflight before the access-key guard (browsers send no credentials)" do
    with_server(agent_config: agent_config) do |server|
      server.instance_variable_set(:@localhost_only, false)
      server.instance_variable_set(:@access_key, "secret")
      res = dispatch_options(server, headers: { "Origin" => "https://app.example.com" })
      expect(res.status).to eq(204)
      expect(res["Access-Control-Allow-Origin"]).to eq("https://app.example.com")
    end
  end

  it "includes Access-Control-Allow-Origin on 404 responses" do
    with_server(agent_config: agent_config) do |server|
      req = fake_req(method: "GET", path: "/api/does-not-exist")
      res = capturing_res
      dispatch(server, req, res)
      expect(res.status).to eq(404)
      expect(res["Access-Control-Allow-Origin"]).to eq("*")
    end
  end
end
