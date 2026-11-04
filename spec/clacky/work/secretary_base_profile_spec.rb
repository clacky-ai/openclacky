# frozen_string_literal: true
require "spec_helper"
require "clacky/server/http_server"
require_relative "../../support/http_server_spec_helpers"

RSpec.describe "Custom profiles based on the secretary extension" do
  include HttpServerSpecHelpers
  let(:dir) { Dir.mktmpdir("secretary-base") }
  let(:config) do
    Clacky::AgentConfig.new(memory_update_enabled: false, enable_idle_compression: false, skill_evolution: { enabled: false }, models: [
      { "model" => "test", "api_key" => "test", "base_url" => "https://example.invalid", "type" => "default" }
    ])
  end
  def write_profile(name, base_agent: "secretary", prompt: "Prefer measurable experiments.")
    path = File.join(dir, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "profile.yml"), YAML.dump({ "name" => name, "title" => "My #{name}", "base_agent" => base_agent }))
    File.write(File.join(path, "system_prompt.md"), prompt)
  end
  before do
    stub_const("Clacky::AgentProfile::USER_AGENTS_DIR", dir)
    write_profile("growth")
    File.write(File.join(dir, "SOUL.md"), "Shared communication style.")
    File.write(File.join(dir, "USER.md"), "Shared user preferences.")
  end
  after { FileUtils.rm_rf(dir) }

  it "composes existing prompt layers and exposes the secretary container tools" do
    profile = Clacky::AgentProfile.load("growth")
    base = Clacky::AgentProfile.load("secretary")
    expect(profile.name).to eq("growth")
    expect(profile.based_on?("secretary")).to be(true)
    expect(profile.system_prompt).to eq(base.system_prompt + "\n\nPrefer measurable experiments.")
    expect(profile.tools).to eq(base.tools)
    expect(profile.container_dir).to eq(base.container_dir)
    expect(profile.soul).to eq("Shared communication style.")
    expect(profile.user_profile).to eq("Shared user preferences.")
    expect(Clacky::AgentProfile.all).to include(hash_including(id: "growth", title: "My growth", source: "user"))
    expect(base.based_on?("secretary")).to be(true)
    expect(Clacky::AgentProfile.load("general").based_on?("secretary")).to be(false)
  end

  it "reuses work tools, panel bindings, schedule validation and session restoration" do
    with_server(agent_config: config) do |server|
      allow(server).to receive(:default_working_dir).and_return(dir)
      sid = server.send(:build_session, name: "Growth", profile: "growth")
      other = server.send(:build_session, name: "Another", profile: "growth")
      registry = server.instance_variable_get(:@registry)
      agent = registry.get(sid)[:agent]
      expect(agent.tool_registry.tool_names).to include("delegate_work", "manage_work")
      expect(server.send(:panel_agents_map)["secretary/work"]).to include("growth", "secretary")
      prompt = agent.send(:build_system_prompt)
      expect(prompt).to include("Prefer measurable experiments.", "Shared communication style.", "Shared user preferences.")
      card = agent.tool_registry.get("delegate_work").execute(title: "Research", task: "Compare acquisition channels")
      expect(card["owner_session_id"]).to eq(sid)
      expect(server.work_service.list(other)).to be_empty
      expect(server.work_service.turn_context(agent)).to include(card["id"])
      expect(agent.tool_registry.get("manage_work").execute(action: "get", work_id: card["id"])["id"]).to eq(card["id"])
      worker = registry.get(card["session_id"])[:agent]
      expect(worker.agent_profile.name).to eq("secretary-worker")
      expect(worker.tool_registry.tool_names).not_to include("terminal", "delegate_work")
      target = server.work_service.schedule_target(sid, title: "Daily report")
      plan = { "id" => "plan-1", "name" => "report", "target" => target }
      expect(server.work_service.dispatch_schedule(plan, "Summarize work", Time.now)["owner_session_id"]).to eq(sid)
      saved = server.instance_variable_get(:@session_manager).load(sid)
      expect(saved[:agent_profile]).to eq("growth")
      expect(saved).not_to have_key(:session_instructions)
      # Same behavior as existing profiles: reload current files, no new snapshots.
      write_profile("growth", prompt: "Focus on retention.")
      restored = Clacky::Agent.from_session(double("client"), config.deep_copy, saved, ui: nil, profile: "growth")
      server.work_service.attach(restored)
      expect(restored.agent_profile.based_on?("secretary")).to be(true)
      expect(restored.send(:build_system_prompt)).to include("Focus on retention.")
      expect(restored.send(:build_system_prompt)).not_to include("Prefer measurable experiments.")
      expect(restored.tool_registry.tool_names).to include("delegate_work", "manage_work")
    end
  end

  it "rejects missing base agents and unavailable extensions" do
    write_profile("invalid", base_agent: "arbitrary-profile")
    expect { Clacky::AgentProfile.load("invalid") }.to raise_error(ArgumentError, /not available/)
    empty = double("extension result", agents: [])
    allow(Clacky::ExtensionLoader).to receive(:last_result).and_return(empty)
    allow(Clacky::ExtensionLoader).to receive(:load_all).and_return(empty)
    expect { Clacky::AgentProfile.load("growth") }.to raise_error(ArgumentError, /not available/)
  end

  it "retains worker restrictions for a customized worker profile" do
    write_profile("custom-worker", base_agent: "secretary-worker")
    with_server(agent_config: config) do |server|
      allow(server).to receive(:default_working_dir).and_return(dir)
      sid = server.send(:build_session, name: "Worker", profile: "custom-worker")
      agent = server.instance_variable_get(:@registry).get(sid)[:agent]
      expect(agent.tool_registry.tool_names).to include("yield_work")
      expect(agent.tool_registry.tool_names).not_to include("terminal", "write", "delegate_work")
      expect { server.work_service.turn_context(agent) }.to raise_error(Clacky::AgentInterrupted)
    end
  end

  it "leaves a plain user profile unchanged" do
    write_profile("plain", base_agent: nil, prompt: "Ordinary custom role")
    profile = Clacky::AgentProfile.load("plain")
    expect(profile.based_on?("secretary")).to be(false)
    expect(profile.tools).to eq([])
    expect(profile.container_dir).to be_nil
    expect(profile.system_prompt).to eq("Ordinary custom role")
  end
end
