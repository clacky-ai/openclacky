# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"
require_relative "../../support/http_server_spec_helpers"

# POST /api/sessions carries the reasoning stop the New Session page picked.
# The picker only offers stops the selected model can express, but the draft
# can outlive a model change, so the server clamps the value the same way
# PATCH /api/sessions/:id/reasoning_effort does.
RSpec.describe Clacky::Server::HttpServer, "POST /api/sessions with reasoning_effort" do
  include HttpServerSpecHelpers

  let(:tmproot)     { Dir.mktmpdir("clacky_create_rsn_spec") }
  let(:config_file) { File.join(tmproot, "config.yml") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      {
        "model"            => "claude-sonnet-4-6",
        "api_key"          => "sk-testkey1234567890abcd",
        "base_url"         => "https://api.example.com",
        "anthropic_format" => true,
        "type"             => "default"
      },
      {
        "model"            => "glm-5.3",
        "api_key"          => "sk-testkey1234567890abcd",
        "base_url"         => "https://api.example.com",
        "anthropic_format" => true
      }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  after { FileUtils.rm_rf(tmproot) }

  def model_id(name)
    agent_config.models.find { |m| m["model"] == name }["id"]
  end

  def create_session(server, body)
    res = fake_res
    dispatch(server, fake_req(method: "POST", path: "/api/sessions", body: body), res)
    [res.status, parsed_body(res)]
  end

  def stored_reasoning(server, session_id)
    server.instance_variable_get(:@registry).snapshot(session_id)[:reasoning_effort]
  end

  it "stores a stop the model can express" do
    with_server(agent_config: agent_config) do |server|
      status, body = create_session(server, {
        name: "rsn-high",
        working_dir: File.join(tmproot, "ws1"),
        model_id: model_id("claude-sonnet-4-6"),
        reasoning_effort: "high"
      })

      expect(status).to eq(201), body.inspect
      expect(stored_reasoning(server, body["session"]["id"])).to eq("high")
    end
  end

  it "snaps an unreachable stop onto the model's nearest one" do
    with_server(agent_config: agent_config) do |server|
      # GLM-5.3 only distinguishes low/high/max; xhigh is not one of its stops.
      status, body = create_session(server, {
        name: "rsn-snap",
        working_dir: File.join(tmproot, "ws2"),
        model_id: model_id("glm-5.3"),
        reasoning_effort: "xhigh"
      })

      expect(status).to eq(201), body.inspect
      expect(stored_reasoning(server, body["session"]["id"])).to eq("high")
    end
  end

  it "keeps the agent default when no stop is sent" do
    with_server(agent_config: agent_config) do |server|
      status, body = create_session(server, {
        name: "rsn-default",
        working_dir: File.join(tmproot, "ws3"),
        model_id: model_id("claude-sonnet-4-6")
      })

      expect(status).to eq(201), body.inspect
      expect(stored_reasoning(server, body["session"]["id"])).to eq("off")
    end
  end

  it "falls back to the default for an unknown stop" do
    with_server(agent_config: agent_config) do |server|
      status, body = create_session(server, {
        name: "rsn-bogus",
        working_dir: File.join(tmproot, "ws4"),
        model_id: model_id("claude-sonnet-4-6"),
        reasoning_effort: "banana"
      })

      expect(status).to eq(201), body.inspect
      expect(stored_reasoning(server, body["session"]["id"])).to eq("off")
    end
  end
end
