# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# tools_allow: a hard per-agent tool whitelist (used by the knowledge agent so
# a public-facing Q&A bot can't run commands, touch files or browse the web).
RSpec.describe Clacky::Agent, "tools_allow whitelist" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:config) do
    c = Clacky::AgentConfig.new(permission_mode: :auto_approve)
    c.add_model(model: "claude-sonnet-4.5", api_key: "test-api-key", base_url: "https://api.anthropic.com")
    c
  end

  after do
    allow(Clacky::ExtensionLoader).to receive(:last_result).and_call_original
    allow(Clacky::ExtensionLoader).to receive(:load_all).and_call_original
  end

  def write_tool(dir, id)
    klass = id.split("_").map(&:capitalize).join
    path = File.join(dir, "tools", "#{id}.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~RUBY)
      module Clacky
        module Tools
          class #{klass} < Base
            self.tool_name = "#{id}"
            self.tool_description = "Test tool"
            self.tool_parameters = { type: "object", properties: {}, required: [] }
            def execute(*_args, **_kwargs)
              { ok: "#{id}" }
            end
          end
        end
      end
    RUBY
  end

  def agent_unit(dir, id, spec = {})
    prompt = File.join(dir, "#{id}.md")
    File.write(prompt, "You are #{id}.")
    Clacky::ExtensionLoader::Unit.new(
      kind: :agent, id: id, ext_id: "demo", layer: :local, origin: "self", dir: dir,
      spec: { "prompt" => "#{id}.md", "prompt_abs" => prompt, "tools" => [] }.merge(spec)
    )
  end

  def tool_unit(dir, id, attach)
    Clacky::ExtensionLoader::Unit.new(
      kind: :tool, id: id, ext_id: "demo", layer: :local, origin: "self", dir: dir,
      spec: { "id" => id, "file" => "tools/#{id}.rb", "file_abs" => File.join(dir, "tools", "#{id}.rb"), "attach" => attach }
    )
  end

  # A restricted "kbq" agent (whitelist kb_probe) next to an unrestricted
  # "plain" agent; one tool attached to kbq, one attached to every agent.
  def stub_result(dir)
    write_tool(dir, "kb_probe")
    write_tool(dir, "everywhere_probe")
    result = Clacky::ExtensionLoader::Result.new(
      panels: [], api: [], skills: [], channels: [], patches: [], hooks: [], errors: [], overridden: [], containers: {},
      agents: [agent_unit(dir, "kbq", "tools_allow" => ["kb_probe"]), agent_unit(dir, "plain")],
      tools: [tool_unit(dir, "kb_probe", ["kbq"]), tool_unit(dir, "everywhere_probe", ["*"])]
    )
    allow(Clacky::ExtensionLoader).to receive(:last_result).and_return(result)
    allow(Clacky::ExtensionLoader).to receive(:load_all).and_return(result)
  end

  def build(profile)
    described_class.new(client, config, working_dir: Dir.pwd, ui: nil, profile: profile,
                        session_id: Clacky::SessionManager.generate_id, source: :manual)
  end

  def registry(agent)
    agent.instance_variable_get(:@tool_registry)
  end

  it "registers and sends only whitelisted tools" do
    Dir.mktmpdir do |dir|
      stub_result(dir)
      agent = build("kbq")
      expect(registry(agent).tool_names).to eq(["kb_probe"])
      expect(registry(agent).all_definitions.map { |d| d.dig(:function, :name) }).to eq(["kb_probe"])
      expect(agent.tools_restricted?).to be(true)
    end
  end

  it "rejects calls to tools outside the whitelist, including aliases" do
    Dir.mktmpdir do |dir|
      stub_result(dir)
      agent = build("kbq")
      calls = [
        { id: "c1", name: "terminal", arguments: '{"command":"ls"}' },
        { id: "c2", name: "write", arguments: '{"path":"/tmp/x","content":"x"}' },
        { id: "c3", name: "rm", arguments: "{}" },
        { id: "c4", name: "everywhere_probe", arguments: "{}" }
      ]
      results = agent.send(:act, calls)[:tool_results]
      expect(results.size).to eq(4)
      results.each { |r| expect(r[:content].to_s).to match(/not found/i) }
    end
  end

  it "leaves unrestricted agents untouched" do
    Dir.mktmpdir do |dir|
      stub_result(dir)
      agent = build("plain")
      names = registry(agent).tool_names
      expect(names).to include("terminal", "write", "web_search", "invoke_skill", "everywhere_probe")
      expect(names).not_to include("kb_probe")
      expect(agent.tools_restricted?).to be(false)
      expect(agent.agent_profile.base_prompt).not_to be_empty
    end
  end

  it "drops base.md, skills and memory work for a restricted agent" do
    Dir.mktmpdir do |dir|
      stub_result(dir)
      agent = build("kbq")
      profile = agent.agent_profile
      expect(profile.base_prompt).to eq("")
      skill = instance_double(Clacky::Skill, identifier: "any", allowed_for_agent?: true)
      expect(profile.skill_allowed?(skill)).to be(false)
      expect(agent.send(:should_update_memory?)).to be(false)
      expect(agent.send(:should_auto_create_skill?)).to be(false)
      prompt = agent.send(:build_system_prompt)
      expect(prompt).not_to include("todo_manager", "invoke_skill")
    end
  end

  it "does not crash the todo reminder when todo_manager is not registered" do
    Dir.mktmpdir do |dir|
      stub_result(dir)
      agent = build("kbq")
      expect(agent.send(:inject_todo_reminder, "kb_probe", { ok: 1 })).to eq({ ok: 1 })
    end
  end

  it "forks subagents with the same whitelist" do
    Dir.mktmpdir do |dir|
      stub_result(dir)
      allow(Clacky::Client).to receive(:new).and_return(client)
      sub = build("kbq").fork_subagent
      expect(registry(sub).tool_names).to eq(["kb_probe"])
    end
  end

  describe Clacky::AgentProfile do
    it "intersects whitelists across base, ext and profile.yml so overrides can only narrow" do
      Dir.mktmpdir do |dir|
        stub_const("Clacky::AgentProfile::USER_AGENTS_DIR", File.join(dir, "agents"))
        stub_result(dir)
        user = File.join(dir, "agents", "my-kbq")
        FileUtils.mkdir_p(user)
        File.write(File.join(user, "profile.yml"), YAML.dump("base_agent" => "kbq", "tools_allow" => %w[kb_probe terminal]))
        profile = described_class.load("my-kbq")
        expect(profile.tools_allow).to eq(["kb_probe"])
        expect(profile.tool_allowed?("terminal")).to be(false)
      end
    end

    it "treats a missing tools_allow as unrestricted" do
      Dir.mktmpdir do |dir|
        stub_result(dir)
        profile = described_class.load("plain")
        expect(profile.tools_allow).to be_nil
        expect(profile.tool_allowed?("terminal")).to be(true)
      end
    end
  end
end
