# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Clacky::Agent::MemoryInjector do
  let(:main_client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:picker) { instance_double(Clacky::Client) }
  let(:config) do
    Clacky::AgentConfig.new(model: "gpt-4o", permission_mode: :auto_approve,
                            memory_update_enabled: false, memory_inject_enabled: true,
                            skill_evolution: { enabled: false })
  end
  let(:memories_dir) { Dir.mktmpdir }
  let(:working_dir) { Dir.mktmpdir }

  after do
    FileUtils.rm_rf(memories_dir)
    FileUtils.rm_rf(working_dir)
  end

  before do
    allow(Clacky::Client).to receive(:new).and_return(picker)
  end

  def build_agent
    agent = Clacky::Agent.new(main_client, config, working_dir: working_dir, ui: nil,
                              profile: "general", session_id: Clacky::SessionManager.generate_id,
                              source: :manual)
    allow(agent).to receive(:think).and_return({ finish_reason: "stop", content: "Done", tool_calls: [] })
    allow(agent).to receive(:inject_memory_prompt!).and_return(false)
    allow(agent).to receive(:memories_base_dir).and_return(memories_dir)
    agent
  end

  def write_memory(name, body, description: "desc of #{name}", mtime: nil)
    path = File.join(memories_dir, name)
    File.write(path, "---\ntopic: #{name}\ndescription: #{description}\n---\n#{body}\n")
    FileUtils.touch(path, mtime: mtime) if mtime
    path
  end

  def picker_returns(*replies, usage: nil)
    responses = replies.map { |text| { content: text, tool_calls: [], finish_reason: "stop", usage: usage } }
    allow(picker).to receive(:send_messages_with_tools).and_return(*responses)
  end

  def recall_messages(agent)
    agent.history.to_a.select { |m| m[:memory_recall] }
  end

  it "does not call the picker when the feature is disabled" do
    config.memory_inject_enabled = false
    write_memory("prefs.md", "Reply in Chinese.")
    agent = build_agent

    agent.run("hello")

    expect(Clacky::Client).not_to have_received(:new)
    expect(recall_messages(agent)).to be_empty
  end

  it "does not call the picker when there are no memories" do
    agent = build_agent

    agent.run("hello")

    expect(Clacky::Client).not_to have_received(:new)
    expect(recall_messages(agent)).to be_empty
  end

  it "injects the selected memory body before the user message" do
    write_memory("prefs.md", "Reply in Chinese.")
    write_memory("other.md", "Unrelated.")
    picker_returns('{"files": ["prefs.md"]}')
    agent = build_agent

    agent.run("how should you reply?")

    msgs = agent.history.to_a
    recall_index = msgs.index { |m| m[:memory_recall] }
    user_index = msgs.index { |m| m[:role] == "user" && m[:content].to_s.include?("how should you reply?") }
    recall = msgs[recall_index]

    expect(recall_index).to be < user_index
    expect(recall[:system_injected]).to be(true)
    expect(recall[:memory_files]).to eq(["prefs.md"])
    expect(recall[:content]).to include("<system-reminder>", "## prefs.md", "Reply in Chinese.")
    expect(recall[:content]).not_to include("description:", "Unrelated.")
  end

  it "sends the shared memory list and the user message to the picker" do
    write_memory("prefs.md", "Reply in Chinese.", description: "language preference")
    picker_returns('{"files": []}')
    agent = build_agent

    agent.run("which language?")

    expect(picker).to have_received(:send_messages_with_tools) do |messages, **opts|
      prompt = messages.last[:content]
      expect(prompt).to include("**prefs.md**", "language preference", "which language?")
      expect(opts[:max_tokens]).to eq(described_class::MEMORY_PICKER_MAX_TOKENS)
    end
  end

  it "lists memories beyond the skills' LRU shortlist to the picker" do
    shortlist = Clacky::Agent::SkillManager::MAX_MEMORIES_META_FILES
    (shortlist + 5).times do |i|
      write_memory("mem-#{i.to_s.rjust(3, "0")}.md", "body", mtime: Time.now - (i * 60))
    end
    picker_returns('{"files": []}')
    agent = build_agent

    agent.run("anything")

    expect(picker).to have_received(:send_messages_with_tools) do |messages, **|
      prompt = messages.last[:content]
      expect(prompt.scan("| topic:").length).to eq(shortlist + 5)
      expect(prompt).not_to include("older memories not listed")
    end
  end

  it "sends both ends of a long previous reply to the picker" do
    write_memory("prefs.md", "Reply in Chinese.")
    picker_returns('{"files": []}')
    agent = build_agent
    half = described_class::MEMORY_PICKER_PREV_REPLY_CHARS / 2
    long_reply = "HEAD#{"a" * half}#{"m" * 5000}#{"z" * half}TAIL"
    agent.history.append({ role: "assistant", content: long_reply })

    agent.run("ok, do it")

    expect(picker).to have_received(:send_messages_with_tools) do |messages, **|
      prompt = messages.last[:content]
      expect(prompt).to include("HEAD", "TAIL", "\n...\n")
      expect(prompt).not_to include("m" * 10)
    end
  end

  it "sends a short previous reply to the picker unchanged" do
    write_memory("prefs.md", "Reply in Chinese.")
    picker_returns('{"files": []}')
    agent = build_agent
    agent.history.append({ role: "assistant", content: "Shall I open the PR?" })

    agent.run("yes")

    expect(picker).to have_received(:send_messages_with_tools) do |messages, **|
      prompt = messages.last[:content]
      expect(prompt).to include("Shall I open the PR?")
      expect(prompt).not_to include("\n...\n")
    end
  end

  it "bills the picker call without touching the main conversation's token stats" do
    write_memory("prefs.md", "Reply in Chinese.")
    picker_returns('{"files": []}', usage: { prompt_tokens: 800, completion_tokens: 20, total_tokens: 820, api_cost: 0.002 })
    agent = build_agent
    store = instance_double(Clacky::Billing::BillingStore, append: nil)
    allow(agent).to receive(:billing_store).and_return(store)
    agent.instance_variable_set(:@previous_total_tokens, 5000)

    agent.run("hi there")

    expect(agent.total_cost).to be_within(1e-9).of(0.002)
    expect(agent.instance_variable_get(:@previous_total_tokens)).to eq(5000)
    expect(agent.instance_variable_get(:@cache_stats)[:total_requests]).to eq(0)
    expect(store).to have_received(:append).with(
      having_attributes(model: config.effective_model_name, prompt_tokens: 800, cost_usd: 0.002)
    )
  end

  it "does not inject a file again while it is still in history" do
    write_memory("prefs.md", "Reply in Chinese.")
    picker_returns('{"files": ["prefs.md"]}')
    agent = build_agent

    agent.run("first")
    agent.run("second")

    expect(recall_messages(agent).size).to eq(1)
  end

  it "re-injects a file once compression has dropped the earlier injection" do
    write_memory("prefs.md", "Reply in Chinese.")
    picker_returns('{"files": ["prefs.md"]}')
    agent = build_agent

    agent.run("first")
    agent.history.delete_where { |m| m[:memory_recall] }
    agent.run("second")

    expect(recall_messages(agent).size).to eq(1)
    expect(recall_messages(agent).first[:content]).to include("Reply in Chinese.")
  end

  it "drops unknown files and path-like names returned by the picker" do
    write_memory("prefs.md", "Reply in Chinese.")
    picker_returns('{"files": ["missing.md", "../secret.md", "prefs.md"]}')
    agent = build_agent

    agent.run("hi there")

    expect(recall_messages(agent).first[:memory_files]).to eq(["prefs.md"])
  end

  it "caps the number of injected files" do
    names = %w[a.md b.md c.md d.md]
    names.each { |n| write_memory(n, "body #{n}") }
    picker_returns({ "files" => names }.to_json)
    agent = build_agent

    agent.run("everything")

    expect(recall_messages(agent).first[:memory_files].size).to eq(described_class::MEMORY_INJECT_MAX_FILES)
  end

  it "extracts JSON wrapped in prose" do
    write_memory("prefs.md", "Reply in Chinese.")
    picker_returns("Sure:\n```json\n{\"files\": [\"prefs.md\"]}\n```")
    agent = build_agent

    agent.run("hi there")

    expect(recall_messages(agent).size).to eq(1)
  end

  [
    ['{"files": []}', "an empty selection"],
    ["not json at all", "an unparseable reply"],
    ['{"files": "prefs.md"}', "a malformed files field"]
  ].each do |reply, label|
    it "injects nothing for #{label}" do
      write_memory("prefs.md", "Reply in Chinese.")
      picker_returns(reply)
      agent = build_agent

      agent.run("hi there")

      expect(recall_messages(agent)).to be_empty
    end
  end

  it "logs and continues when the picker call fails" do
    write_memory("prefs.md", "Reply in Chinese.")
    allow(picker).to receive(:send_messages_with_tools).and_raise(Faraday::TimeoutError, "timeout")
    allow(Clacky::Logger).to receive(:warn)
    agent = build_agent

    result = agent.run("hi there")

    expect(recall_messages(agent)).to be_empty
    expect(Clacky::Logger).to have_received(:warn).with("memory_inject.failed", error: kind_of(StandardError))
    expect(result[:status]).to eq(:success)
  end

  it "warns when the picker reply is cut off by max_tokens" do
    write_memory("prefs.md", "Reply in Chinese.")
    allow(picker).to receive(:send_messages_with_tools).and_return(
      { content: '{"files": ["prefs', tool_calls: [], finish_reason: "length", usage: nil }
    )
    allow(Clacky::Logger).to receive(:warn)
    agent = build_agent

    agent.run("how should you reply?")

    expect(recall_messages(agent)).to be_empty
    expect(Clacky::Logger).to have_received(:warn).with("memory_inject.picker_truncated", hash_including(max_tokens: described_class::MEMORY_PICKER_MAX_TOKENS))
  end

  it "uses the lite model when one is available" do
    write_memory("prefs.md", "Reply in Chinese.")
    picker_returns('{"files": []}')
    allow(config).to receive(:lite_model_config_for_current).and_return(
      "api_key" => "lite-key", "base_url" => "https://lite.example", "model" => "lite-model",
      "anthropic_format" => true, "virtual" => true
    )
    agent = build_agent

    agent.run("hi there")

    expect(Clacky::Client).to have_received(:new).with(
      "lite-key", hash_including(base_url: "https://lite.example", model: "lite-model", anthropic_format: true)
    )
    expect(picker).to have_received(:send_messages_with_tools).with(anything, hash_including(model: "lite-model"))
  end

  it "falls back to the primary model when no lite model is available" do
    write_memory("prefs.md", "Reply in Chinese.")
    picker_returns('{"files": []}')
    allow(config).to receive(:lite_model_config_for_current).and_return(nil)
    agent = build_agent

    agent.run("hi there")

    expect(picker).to have_received(:send_messages_with_tools).with(anything, hash_including(model: config.effective_model_name))
  end

  it "adds a staleness note for old memories" do
    write_memory("old.md", "Old fact.", mtime: Time.now - (90 * 86_400))
    picker_returns('{"files": ["old.md"]}')
    agent = build_agent

    agent.run("hi there")

    expect(recall_messages(agent).first[:content]).to match(/9\d days old/)
  end

  it "truncates long memory bodies and points to the file" do
    path = write_memory("long.md", "x" * (described_class::MEMORY_INJECT_FILE_BYTES + 500))
    picker_returns('{"files": ["long.md"]}')
    agent = build_agent

    agent.run("hi there")

    expect(recall_messages(agent).first[:content]).to include("truncated; read #{path}")
  end

  it "never injects into subagents" do
    write_memory("prefs.md", "Reply in Chinese.")
    agent = build_agent
    agent.instance_variable_set(:@is_subagent, true)

    agent.run("hi there")

    expect(Clacky::Client).not_to have_received(:new)
  end

  it "strips memory bookkeeping fields before sending to the API" do
    history = Clacky::MessageHistory.new([
      { role: "user", content: "x", system_injected: true, memory_recall: true, memory_files: ["a.md"] }
    ])

    expect(history.to_api.first.keys).to contain_exactly(:role, :content)
  end
end
