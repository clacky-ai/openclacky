# frozen_string_literal: true

RSpec.describe "Agent#restore_session refreshes system prompt" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:config) do
    Clacky::AgentConfig.new(model: "gpt-3.5-turbo", permission_mode: :auto_approve)
  end

  # Build a minimal session_data hash that restore_session accepts,
  # with a stale system prompt that mentions only old-skill.
  def minimal_session_data(working_dir:)
    {
      session_id: "test-session-abc",
      working_dir: working_dir,
      created_at: Time.now.iso8601,
      todos: [],
      messages: [
        { role: "system",  content: "old system prompt — skill: old-skill" },
        { role: "user",    content: "Hello" },
        { role: "assistant", content: "Hi there!" }
      ],
      stats: {
        total_tasks: 1,
        total_iterations: 2,
        total_cost_usd: 0.01,
        last_status: "success"
      },
      time_machine: { task_parents: {}, current_task_id: 0, active_task_id: 0 }
    }
  end

  it "replaces stale system message with a freshly built system prompt on restore" do
    Dir.mktmpdir do |tmpdir|
      # Create a new skill in the working directory *after* the session was saved
      skill_dir = File.join(tmpdir, ".clacky", "skills", "new-skill")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), <<~MD)
        ---
        name: new-skill
        description: A brand-new skill added after session was saved
        ---

        This is the new skill content.
      MD

      # Isolate from user's global/brand skills so the test is deterministic.
      # Without this, MAX_CONTEXT_SKILLS may drop the project skill when too many
      # other skills are installed.
      allow_any_instance_of(Clacky::SkillLoader).to receive(:load_global_clacky_skills).and_return([])
      allow_any_instance_of(Clacky::SkillLoader).to receive(:load_brand_skills).and_return([])

      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id, source: :manual)
      session_data = minimal_session_data(working_dir: tmpdir)

      agent.restore_session(session_data)

      system_msg = agent.history.to_a.find { |m| m[:role] == "system" }
      expect(system_msg).not_to be_nil

      # The stale "old-skill" text should be gone
      expect(system_msg[:content]).not_to include("old system prompt")

      # The new skill should appear in the rebuilt system prompt
      expect(system_msg[:content]).to include("new-skill")
    end
  end

  it "preserves conversation history (non-system messages) after restore" do
    Dir.mktmpdir do |tmpdir|
      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id, source: :manual)
      session_data = minimal_session_data(working_dir: tmpdir)

      agent.restore_session(session_data)

      non_system = agent.history.to_a.reject { |m| m[:role] == "system" }
      expect(non_system.map { |m| m[:role] }).to eq(%w[user assistant])
      expect(non_system.first[:content]).to eq("Hello")
    end
  end

  it "does not duplicate system messages after restore" do
    Dir.mktmpdir do |tmpdir|
      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id, source: :manual)
      session_data = minimal_session_data(working_dir: tmpdir)

      agent.restore_session(session_data)

      system_messages = agent.history.to_a.select { |m| m[:role] == "system" }
      expect(system_messages.size).to eq(1)
    end
  end
end
