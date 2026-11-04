# frozen_string_literal: true
require "spec_helper"
require "clacky/server/http_server"
require_relative "../support/http_server_spec_helpers"

RSpec.describe "Extension-backed custom agent profiles" do
  include HttpServerSpecHelpers
  let(:dir) { Dir.mktmpdir("base-agent") }
  let(:config) do
    Clacky::AgentConfig.new(memory_update_enabled: false, enable_idle_compression: false, skill_evolution: { enabled: false }, models: [
      { "model" => "test", "api_key" => "test", "base_url" => "https://example.invalid", "type" => "default" }
    ])
  end
  before do
    stub_const("Clacky::AgentProfile::USER_AGENTS_DIR", File.join(dir, "agents"))
    stub_const("Clacky::ExtensionLoader::LOCAL_DIR", File.join(dir, "extensions"))
    stub_const("Clacky::ExtensionLoader::INSTALLED_DIR", File.join(dir, "installed"))
    @extension = File.join(dir, "extensions", "analysis-pack")
    FileUtils.mkdir_p(File.join(@extension, "tools"))
    File.write(File.join(@extension, "ext.yml"), <<~YAML)
      id: analysis-pack
      origin: self
      contributes:
        agents:
          - id: analyst
            prompt: analyst.md
            tools: [base_profile_probe]
            panels: [findings]
            disabled_skills: [unsafe-skill]
          - id: chained
            base_agent: analyst
            prompt: analyst.md
        tools:
          - id: base_profile_probe
            file: tools/base_profile_probe.rb
        panels:
          - id: findings
            view: findings.js
          - id: attached
            view: findings.js
            attach: [analyst]
    YAML
    File.write(File.join(@extension, "analyst.md"), "Shared analyst rules.")
    File.write(File.join(@extension, "findings.js"), "// test panel")
    File.write(File.join(@extension, "tools", "base_profile_probe.rb"), <<~RUBY)
      module Clacky::Tools
        class BaseProfileProbe < Base
          self.tool_name = "base_profile_probe"
          self.tool_description = "Test extension tool"
          self.tool_parameters = { type: "object", properties: {} }
          def execute(**); { message: "ok" }; end
        end
      end
    RUBY
    FileUtils.mkdir_p(File.join(dir, "agents", "my-analyst"))
    @profile_file = File.join(dir, "agents", "my-analyst", "profile.yml")
    File.write(@profile_file, YAML.dump({ "name" => "my-analyst", "base_agent" => "analyst", "disabled_skills" => ["local-disabled"], "tools" => ["must-not-be-added"] }))
    File.write(File.join(dir, "agents", "my-analyst", "system_prompt.md"), "Focus on customer feedback.")
    Clacky::ExtensionLoader.load_all(force: true)
  end
  after do
    FileUtils.rm_rf(dir)
    Clacky::ExtensionLoader.instance_variable_set(:@last_result, nil)
  end

  it "reuses an arbitrary extension's prompt, tools, skill restrictions and panels" do
    profile = Clacky::AgentProfile.load("my-analyst")
    expect(profile.name).to eq("my-analyst")
    expect(profile.based_on?("analyst")).to be(true)
    expect(profile.based_on?("secretary")).to be(false)
    expect(profile.system_prompt).to eq("Shared analyst rules.\n\nFocus on customer feedback.")
    expect(profile.container_dir).to eq(@extension)
    expect(profile.tools).to eq(["base_profile_probe"])
    expect(profile.disabled_skills).to contain_exactly("unsafe-skill", "local-disabled")
    allowed = double("skill", identifier: "analyst-only")
    allow(allowed).to receive(:allowed_for_agent?) { |name| name == "analyst" }
    expect(profile.skill_allowed?(allowed)).to be(true)
    expect(profile.skill_allowed?(double(identifier: "unsafe-skill"))).to be(false)
    with_server(agent_config: config) do |server|
      allow(server).to receive(:default_working_dir).and_return(dir)
      sid = server.send(:build_session, name: "Customer analyst", profile: "my-analyst")
      agent = server.instance_variable_get(:@registry).get(sid)[:agent]
      expect(agent.tool_registry.tool_names).to include("base_profile_probe")
      expect(agent.tool_registry.tool_names).not_to include("delegate_work", "must-not-be-added")
      expect(agent.tool_registry.get("base_profile_probe").execute).to eq(message: "ok")
      map = server.send(:panel_agents_map)
      expect(map["analysis-pack/findings"]).to include("my-analyst")
      expect(map["analysis-pack/attached"]).to include("my-analyst")
      expect { server.work_service.delegate(agent, title: "No", task: "No") }.to raise_error(/no work_agent/)
    end
  end

  it "executes a third-party worker tool and honors end_turn without a special tool name" do
    manifest = File.join(@extension, "ext.yml")
    data = YAML.safe_load(File.read(manifest))
    data["contributes"]["agents"] << { "id" => "work-owner", "prompt" => "analyst.md", "work_agent" => "analyst" }
    File.write(manifest, YAML.dump(data))
    File.write(@profile_file, YAML.dump({ "base_agent" => "work-owner" }))
    tool_file = File.join(@extension, "tools", "base_profile_probe.rb")
    File.write(tool_file, File.read(tool_file).sub('def execute(**); { message: "ok" }; end', <<~RUBY.strip))
      def execute(**)
        File.write(File.join(agent.working_dir, "extension-result.txt"), "third-party output")
        agent.work_service.yield_work(agent, reason: "completed", summary: "Output created")
      end
    RUBY
    Clacky::ExtensionLoader.load_all(force: true)
    expect(Clacky::AgentProfile.load("my-analyst").work_agent).to eq("analyst")
    with_server(agent_config: config) do |server|
      allow(server).to receive(:default_working_dir).and_return(dir)
      registry = server.instance_variable_get(:@registry)
      sid = server.send(:build_session, name: "Third-party owner", profile: "my-analyst")
      owner = registry.get(sid)[:agent]
      card = server.work_service.delegate(owner, title: "Output", task: "Create an output")
      worker = registry.get(card["session_id"])[:agent]
      expect(worker.agent_profile.name).to eq("analyst")
      expect { server.work_service.guard!(worker) }.to raise_error(Clacky::AgentInterrupted)
      allow(worker).to receive(:think) do
        calls = [
          { id: "custom", name: "base_profile_probe", arguments: "{}" },
          { id: "skipped", name: "write", arguments: JSON.generate(path: File.join(dir, "unexpected.txt"), content: "bad") }
        ]
        worker.history.append(role: "assistant", content: nil, tool_calls: calls)
        { content: nil, tool_calls: calls }
      end
      server.work_service.tick
      expect(registry.get(card["session_id"])[:thread].join(5)).not_to be_nil
      expect(File.read(File.join(dir, "extension-result.txt"))).to eq("third-party output")
      expect(File.exist?(File.join(dir, "unexpected.txt"))).to be(false)
      expect(worker).to have_received(:think).once
      expect(server.work_service.list(sid).first["status"]).to eq("completed")
      expect { server.work_service.guard!(worker) }.to raise_error(Clacky::AgentInterrupted)
    end
  end

  it "rejects an unavailable worker before creating a work card" do
    File.write(@profile_file, YAML.dump({ "base_agent" => "analyst", "work_agent" => "missing-worker" }))
    with_server(agent_config: config) do |server|
      sid = server.send(:build_session, name: "Owner", profile: "my-analyst")
      owner = server.instance_variable_get(:@registry).get(sid)[:agent]
      expect { server.work_service.delegate(owner, title: "No", task: "No") }.to raise_error(ArgumentError, /not found/)
      expect(server.work_service.list(sid)).to be_empty
    end
  end

  it "rejects chains and references to user-only profiles" do
    File.write(@profile_file, YAML.dump({ "base_agent" => "chained" }))
    expect { Clacky::AgentProfile.load("my-analyst") }.to raise_error(ArgumentError, /Chained/)
    File.write(@profile_file, YAML.dump({ "base_agent" => "my-analyst" }))
    expect { Clacky::AgentProfile.load("my-analyst") }.to raise_error(ArgumentError, /not available/)
  end
end
