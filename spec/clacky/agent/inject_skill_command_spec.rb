# frozen_string_literal: true

RSpec.describe "Agent#inject_skill_command_as_assistant_message" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:config) { Clacky::AgentConfig.new(model: "gpt-3.5-turbo", permission_mode: :auto_approve) }

  # Helper: create a temp skill with given frontmatter flags
  def create_skill(dir, name:, disable_model_invocation: false, user_invocable: true, content: "Skill instructions here.")
    skill_dir = File.join(dir, ".clacky", "skills", name)
    FileUtils.mkdir_p(skill_dir)
    frontmatter = ["---", "name: #{name}", "description: Test skill #{name}"]
    frontmatter << "disable-model-invocation: true" if disable_model_invocation
    frontmatter << "user-invocable: #{user_invocable}"
    frontmatter << "---"
    File.write(File.join(skill_dir, "SKILL.md"), (frontmatter + ["", content]).join("\n"))
  end

  it "injects assistant message with skill content when skill has disable-model-invocation: true" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "onboard", disable_model_invocation: true, content: "Onboard the user now.")

      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id)

      # Stub run's LLM call so we can inspect messages without hitting the API
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      agent.run("/onboard")

      assistant_msgs = agent.history.to_a.select { |m| m[:role] == "assistant" && m[:system_injected] }
      expect(assistant_msgs.size).to eq(1)
      expect(assistant_msgs.first[:content]).to include("Onboard the user now.")
    end
  end

  it "appends a synthetic user shim message after skill injection for Claude compat" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "onboard", disable_model_invocation: true, content: "Onboard the user now.")

      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id)
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      agent.run("/onboard")

      # After the injected assistant message there must be a user shim so the
      # conversation sequence ends with a user turn (required by Claude / Anthropic API).
      # Exclude session_context messages which are also system_injected but unrelated to skills.
      all_msgs = agent.history.to_a
      injected_msgs = all_msgs.select { |m| m[:system_injected] && !m[:session_context] }
      expect(injected_msgs.size).to eq(2)

      assistant_shim = injected_msgs.find { |m| m[:role] == "assistant" }
      user_shim      = injected_msgs.find { |m| m[:role] == "user" }

      expect(assistant_shim).not_to be_nil
      expect(user_shim).not_to be_nil
      expect(user_shim[:content]).to include("proceed")

      # The user shim must appear immediately after the assistant shim
      assistant_idx = all_msgs.index(assistant_shim)
      user_idx      = all_msgs.index(user_shim)
      expect(user_idx).to eq(assistant_idx + 1)
    end
  end

  it "passes arguments as part of the expanded skill content" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "onboard", disable_model_invocation: true, content: "Task: \$ARGUMENTS")

      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id)
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      agent.run("/onboard hello world")

      injected = agent.history.to_a.find { |m| m[:role] == "assistant" && m[:system_injected] }
      expect(injected[:content]).to include("hello world")
    end
  end

  it "also injects for skills that are model-invocable (slash command is always direct)" do
    Dir.mktmpdir do |tmpdir|
      # No disable-model-invocation: true => model_invocation_allowed? == true
      create_skill(tmpdir, name: "my-skill", disable_model_invocation: false, content: "Normal skill content.")

      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id)
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      agent.run("/my-skill")

      injected = agent.history.to_a.select { |m| m[:role] == "assistant" && m[:system_injected] }
      expect(injected.size).to eq(1)
      expect(injected.first[:content]).to include("Normal skill content.")
    end
  end

  it "does NOT inject when input is not a slash command" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "onboard", disable_model_invocation: true, content: "Onboard.")

      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id)
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      agent.run("just a normal message")

      # Only check skill-injected messages; session_context messages are also system_injected but expected
      injected = agent.history.to_a.select { |m| m[:system_injected] && !m[:session_context] }
      expect(injected).to be_empty
    end
  end
end

# ── inject_skill_as_assistant_message ─────────────────────────────

RSpec.describe "Agent#inject_skill_as_assistant_message" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:config) { Clacky::AgentConfig.new(model: "gpt-3.5-turbo", permission_mode: :auto_approve) }

  def create_skill(dir, name:, content: "Skill content.", encrypted: false)
    if encrypted
      # Brand skill: write SKILL.md.enc under brand_skills/
      skill_dir = File.join(dir, ".clacky", "brand_skills", name)
      FileUtils.mkdir_p(skill_dir)
      skill_md = "---\nname: #{name}\ndescription: Brand skill #{name}\n---\n\n#{content}"
      File.binwrite(File.join(skill_dir, "SKILL.md.enc"), skill_md)
      skill_dir
    else
      skill_dir = File.join(dir, ".clacky", "skills", name)
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: #{name}\ndescription: Test skill #{name}\n---\n\n#{content}")
      skill_dir
    end
  end

  def build_agent(tmpdir)
    agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil, profile: "general", session_id: Clacky::SessionManager.generate_id)
    allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
    allow(agent).to receive(:inject_memory_prompt!).and_return(false)
    agent
  end

  it "injects assistant message + user shim into history" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "my-skill", content: "Do the thing.")
      agent = build_agent(tmpdir)
      skill = agent.instance_variable_get(:@skill_loader).find_by_name("my-skill")

      agent.send(:inject_skill_as_assistant_message, skill, "arg1", 1)

      injected = agent.history.to_a.select { |m| m[:system_injected] && !m[:session_context] }
      expect(injected.size).to eq(2)
      expect(injected[0][:role]).to eq("assistant")
      expect(injected[0][:content]).to include("Do the thing.")
      expect(injected[1][:role]).to eq("user")
      expect(injected[1][:content]).to include("proceed")
    end
  end

  it "substitutes arguments in skill content" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "my-skill", content: "Task: $ARGUMENTS")
      agent = build_agent(tmpdir)
      skill = agent.instance_variable_get(:@skill_loader).find_by_name("my-skill")

      agent.send(:inject_skill_as_assistant_message, skill, "hello world", 1)

      injected = agent.history.to_a.find { |m| m[:role] == "assistant" && m[:system_injected] }
      expect(injected[:content]).to include("hello world")
    end
  end

  it "does NOT mark injected messages as transient for plain skills" do
    Dir.mktmpdir do |tmpdir|
      create_skill(tmpdir, name: "my-skill", content: "Plain content.")
      agent = build_agent(tmpdir)
      skill = agent.instance_variable_get(:@skill_loader).find_by_name("my-skill")

      agent.send(:inject_skill_as_assistant_message, skill, "", 1)

      injected = agent.history.to_a.select { |m| m[:system_injected] && !m[:session_context] }
      expect(injected).to all(satisfy { |m| !m[:transient] })
    end
  end

  # Helper: stub CONFIG_DIR + temporarily unset CLACKY_TEST (same pattern as brand_skill_spec.rb)
  # so load_brand_skills is not short-circuited in test env.
  def with_brand_skill(name:, content:)
    Dir.mktmpdir do |tmp|
      stub_const("Clacky::BrandConfig::CONFIG_DIR", tmp)
      stub_const("Clacky::BrandConfig::BRAND_FILE", File.join(tmp, "brand.yml"))

      brand_config = Clacky::BrandConfig.new(
        "brand_name"           => "TestBrand",
        "license_key"          => "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4",
        "license_activated_at" => Time.now.utc.iso8601,
        "license_expires_at"   => (Time.now.utc + 86_400).iso8601,
        "device_id"            => "testdevice"
      )
      allow(Clacky::BrandConfig).to receive(:load).and_return(brand_config)

      # Brand skill lives at CONFIG_DIR/brand_skills/<name>/SKILL.md.enc
      skill_dir = File.join(tmp, "brand_skills", name)
      FileUtils.mkdir_p(skill_dir)
      File.binwrite(
        File.join(skill_dir, "SKILL.md.enc"),
        "---\nname: #{name}\ndescription: Brand skill\n---\n\n#{content}"
      )

      # Temporarily unset CLACKY_TEST so load_brand_skills guard doesn't short-circuit.
      old_test_env = ENV.delete("CLACKY_TEST")
      begin
        yield tmp, brand_config
      ensure
        ENV["CLACKY_TEST"] = old_test_env if old_test_env
      end
    end
  end

  it "marks injected messages as transient for brand skills (encrypted)" do
    with_brand_skill(name: "secret-skill", content: "Secret instructions.") do |tmpdir|
      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil,
                                profile: "general",
                                session_id: Clacky::SessionManager.generate_id)
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      skill = agent.instance_variable_get(:@skill_loader).find_by_name("secret-skill")
      expect(skill).not_to be_nil
      expect(skill.encrypted?).to be true

      agent.send(:inject_skill_as_assistant_message, skill, "", 1)

      # Use raw @messages (not to_a) because to_a already filters out transient messages.
      raw_messages = agent.history.instance_variable_get(:@messages)
      injected = raw_messages.select { |m| m[:system_injected] && !m[:session_context] }
      expect(injected.size).to eq(2)
      expect(injected).to all(satisfy { |m| m[:transient] == true })
    end
  end

  it "transient messages are excluded from to_a (not persisted to session.json)" do
    with_brand_skill(name: "secret-skill", content: "Secret instructions.") do |tmpdir|
      agent = Clacky::Agent.new(client, config, working_dir: tmpdir, ui: nil,
                                profile: "general",
                                session_id: Clacky::SessionManager.generate_id)
      allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
      allow(agent).to receive(:inject_memory_prompt!).and_return(false)

      skill = agent.instance_variable_get(:@skill_loader).find_by_name("secret-skill")
      agent.send(:inject_skill_as_assistant_message, skill, "", 1)

      # to_a excludes transient messages — brand skill content must not appear
      persisted = agent.history.to_a
      expect(persisted.none? { |m| m[:content].to_s.include?("Secret instructions.") }).to be true
    end
  end
end
