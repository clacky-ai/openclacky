# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Clacky::Tools::InvokeSkill do
  let(:tool) { described_class.new }

  # ── helpers ──────────────────────────────────────────────────────────────────

  def create_skill(dir, name:, content: "Skill content.", fork_agent: false)
    skill_dir = File.join(dir, ".clacky", "skills", name)
    FileUtils.mkdir_p(skill_dir)
    frontmatter = ["---", "name: #{name}", "description: Test skill #{name}"]
    frontmatter << "fork_agent: true" if fork_agent
    frontmatter << "---"
    File.write(File.join(skill_dir, "SKILL.md"), (frontmatter + ["", content]).join("\n"))
    skill_dir
  end

  def build_agent(tmpdir)
    client = instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
    config = Clacky::AgentConfig.new(model: "gpt-3.5-turbo", permission_mode: :auto_approve)
    agent  = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil,
                               profile: "general",
                               session_id: Clacky::SessionManager.generate_id)
    allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
    allow(agent).to receive(:inject_memory_prompt!).and_return(false)
    agent
  end

  # ── error cases ───────────────────────────────────────────────────────────────

  it "returns error when agent is nil" do
    result = tool.execute(skill_name: "anything", task: "do it", agent: nil, skill_loader: double)
    expect(result[:error]).to match(/Agent context/)
  end

  it "returns error when skill_loader is nil" do
    result = tool.execute(skill_name: "anything", task: "do it", agent: double, skill_loader: nil)
    expect(result[:error]).to match(/Skill loader/)
  end

  it "returns error when skill is not found" do
    Dir.mktmpdir do |tmpdir|
      agent  = build_agent(tmpdir)
      loader = agent.instance_variable_get(:@skill_loader)

      result = tool.execute(skill_name: "nonexistent", task: "do it", agent: agent, skill_loader: loader)
      expect(result[:error]).to match(/not found/)
    end
  end

  # ── inline path ───────────────────────────────────────────────────────────────

  it "delegates to inject_skill_as_assistant_message for plain inline skills" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "my-skill", content: "Do the thing.")
      agent  = build_agent(tmpdir)
      loader = agent.instance_variable_get(:@skill_loader)

      expect(agent).to receive(:inject_skill_as_assistant_message).once
      result = tool.execute(skill_name: "my-skill", task: "run it", agent: agent, skill_loader: loader)

      expect(result[:skill_type]).to eq("inline")
      expect(result[:error]).to be_nil
    end
  end

  it "injects assistant + user shim messages into agent history for inline skills" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "my-skill", content: "Do the thing.")
      agent  = build_agent(tmpdir)
      loader = agent.instance_variable_get(:@skill_loader)

      tool.execute(skill_name: "my-skill", task: "run it", agent: agent, skill_loader: loader)

      injected = agent.history.to_a.select { |m| m[:system_injected] && !m[:session_context] }
      expect(injected.size).to eq(2)
      expect(injected[0][:role]).to eq("assistant")
      expect(injected[0][:content]).to include("Do the thing.")
      expect(injected[1][:role]).to eq("user")
    end
  end

  it "does NOT return skill content in the tool result (content lives in history, not tool result)" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "my-skill", content: "Secret content.")
      agent  = build_agent(tmpdir)
      loader = agent.instance_variable_get(:@skill_loader)

      result = tool.execute(skill_name: "my-skill", task: "run it", agent: agent, skill_loader: loader)

      # Skill content must NOT be in the tool result — it goes into history directly
      expect(result.to_s).not_to include("Secret content.")
    end
  end

  # ── fork_agent path ───────────────────────────────────────────────────────────

  it "executes in subagent when skill has fork_agent: true" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "forked-skill", content: "Forked.", fork_agent: true)
      agent  = build_agent(tmpdir)
      loader = agent.instance_variable_get(:@skill_loader)

      # Stub subagent execution — we just verify the right path is taken
      allow(agent).to receive(:execute_skill_with_subagent).and_return("subagent summary")

      result = tool.execute(skill_name: "forked-skill", task: "do it", agent: agent, skill_loader: loader)

      expect(result[:skill_type]).to eq("subagent")
      expect(agent).to have_received(:execute_skill_with_subagent)
    end
  end

  it "does NOT inject history messages when skill runs in subagent" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "forked-skill", content: "Forked.", fork_agent: true)
      agent  = build_agent(tmpdir)
      loader = agent.instance_variable_get(:@skill_loader)

      allow(agent).to receive(:execute_skill_with_subagent).and_return("subagent summary")

      tool.execute(skill_name: "forked-skill", task: "do it", agent: agent, skill_loader: loader)

      injected = agent.history.to_a.select { |m| m[:system_injected] && !m[:session_context] }
      expect(injected).to be_empty
    end
  end

  # ── format helpers ────────────────────────────────────────────────────────────

  describe "#format_call" do
    it "returns formatted skill name" do
      expect(tool.format_call({ skill_name: "code-explorer" })).to eq("InvokeSkill(code-explorer)")
      expect(tool.format_call({ "skill_name" => "pptx" })).to eq("InvokeSkill(pptx)")
    end
  end

  describe "#format_result" do
    it "returns error message on error" do
      expect(tool.format_result({ error: "Skill not found" })).to match(/Error/)
    end

    it "returns subagent message for subagent type" do
      expect(tool.format_result({ skill_type: "subagent" })).to match(/[Ss]ubagent/)
    end

    it "returns injected message for inline type" do
      expect(tool.format_result({ skill_type: "inline" })).to be_a(String)
    end
  end
end
