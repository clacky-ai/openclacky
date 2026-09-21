# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Agent, "on_start hook control" do
  let(:config) do
    Clacky::AgentConfig.new(memory_update_enabled: false, skill_evolution: { enabled: false })
  end
  let(:client) { Clacky::Client.new("test", base_url: "https://unused.invalid", model: "test") }
  let(:ui) { double("ui").as_null_object }
  let(:session_id) { Clacky::SessionManager.generate_id }
  let(:agent) do
    described_class.new(client, config, working_dir: Dir.pwd, ui: ui, profile: "coding",
                         session_id: session_id, source: :web)
  end

  def user_messages
    agent.history.to_a.select { |message| message[:role] == "user" && !message[:system_injected] }
  end

  before do
    allow(agent).to receive(:think).and_return({ content: "done", tool_calls: [] })
    allow(agent).to receive(:run_skill_evolution_hooks)
    allow(agent).to receive(:run_memory_update_subagent)
    allow(Clacky::Telemetry).to receive(:task!)
  end

  [nil, { action: :allow }].each do |verdict|
    it "preserves parameters, timing and normal execution for #{verdict.inspect}" do
      seen = []
      agent.add_hook(:on_start) do |input, owner|
        expect(input).to eq("request")
        expect(owner).to equal(agent)
        expect(owner.total_tasks).to eq(1)
        expect(user_messages).to contain_exactly(hash_including(content: "request", created_at: 123))
        expect(owner.history.to_api.map { |message| message[:content] }).to include("reference")
        seen << :first
        verdict
      end
      agent.add_hook(:on_start) { seen << :second; nil }
      agent.add_hook(:on_complete) { seen << :complete }

      expect(agent.run("request", reference_contexts: ["reference"], created_at: 123)[:status]).to eq(:success)
      expect(seen).to eq(%i[first second complete])
      expect(agent).to have_received(:think).once
    end
  end

  it "keeps existing fail-open behavior when a callback raises" do
    agent.add_hook(:on_start) { raise "callback failed" }
    agent.add_hook(:on_start) { |input| expect(input).to eq("request"); nil }

    expect(agent.run("request")[:status]).to eq(:success)
    expect(agent).to have_received(:think).once
  end

  %i[deny handled].each do |action|
    it "stops on #{action} without completion work and still cleans up the started task" do
      replacement = { status: :success, awaiting_user_feedback: true, queue_paused: true }.freeze
      agent.add_hook(:on_start) do
        agent.enqueue_input("later guidance", delivery: :steer)
        { action: action, reason: "blocked", result: replacement }
      end
      later = double("later hooks")
      expect(later).not_to receive(:call)
      agent.add_hook(:on_start) { later.call }
      agent.add_hook(:on_iteration) { later.call }
      agent.add_hook(:on_complete) { later.call }
      expect(agent).not_to receive(:maybe_continue_goal)

      result = agent.run("request")

      expect(result).to include(status: :success, queue_paused: true)
      expect(result).to equal(replacement) if action == :handled
      if action == :deny
        expect(result).to include(task_id: user_messages.first[:task_id], iterations: 0)
        expect(ui).to have_received(:show_warning).with("blocked")
      end
      expect(agent.total_tasks).to eq(1)
      expect(user_messages).to contain_exactly(hash_including(content: "request"))
      expect(agent).not_to have_received(:think)
      expect(agent).not_to have_received(:run_skill_evolution_hooks)
      expect(agent).not_to have_received(:run_memory_update_subagent)
      expect(ui).not_to have_received(:show_complete)
      expect(ui).to have_received(:show_progress).with(phase: "done")
      expect(agent.instance_variable_get(:@accepting_steering)).to be(false)
      expect(agent.pending_inputs).to contain_exactly(hash_including(content: "later guidance", delivery: "queue"))
      expect(Clacky::Telemetry).to have_received(:task!).with(result: result)
    end

    it "pauses subsequent queued tasks on #{action} and permits a later allowed turn" do
      agent.add_hook(:on_start) do |input|
        next if input == "continue"

        { action: action, result: { status: :success, awaiting_user_feedback: true, queue_paused: true } }
      end
      agent.enqueue_input("request")
      agent.enqueue_input("later task")

      result = agent.run_pending_input(agent.take_pending_input)

      expect(described_class.task_completed?(result)).to be(false)
      expect(agent.pending_inputs.map { |entry| entry[:content] }).to eq(["later task"])
      expect(agent).not_to have_received(:think)
      expect(agent.run("continue")[:status]).to eq(:success)
      expect(agent).to have_received(:think).once
      expect(user_messages.map { |message| message[:content] }).to eq(%w[request continue])
      expect(agent.total_tasks).to eq(2)
    end
  end

  it "shows a default warning when deny has no reason" do
    agent.add_hook(:on_start) { { action: :deny } }

    agent.run("request")

    expect(ui).to have_received(:show_warning).with("Task denied by hook")
  end

  it "does not add start callbacks for steering messages" do
    seen = []
    agent.add_hook(:on_start) { |input| seen << input; nil }
    calls = 0
    allow(agent).to receive(:think) do
      calls += 1
      agent.enqueue_input("guidance", delivery: :steer) if calls == 1
      { content: "done", tool_calls: [] }
    end

    agent.run("request")

    expect(seen).to eq(["request"])
    expect(agent).to have_received(:think).twice
    expect(user_messages.map { |message| message[:content] }).to eq(%w[request guidance])
  end

  it "keeps goal control commands outside on_start" do
    expect(agent.instance_variable_get(:@hooks)).not_to receive(:trigger).with(:on_start, anything)
    expect(agent.run("/goal status")[:status]).to eq(:success)
    expect(agent.total_tasks).to eq(0)
  end

  context "with an extension-owned native Ask" do
    let(:events) { [] }
    let(:ui) { Clacky::Server::WebUIController.new(session_id, ->(_id, event) { events << event }) }

    it "supports repeated asks, native replay, and a later allowed answer without duplicating input" do
      tool_hooks = []
      agent.add_hook(:before_tool_use) { |call| tool_hooks << call[:name]; nil }
      agent.add_hook(:on_start) do |input, owner|
        next if input == "Confirm"

        call = { id: "ask-#{owner.total_tasks}", name: "ask_user",
                 arguments: JSON.generate(question: "Continue?", options: ["Confirm", "Review again"]) }
        response = { content: "", tool_calls: [call] }
        owner.history.append(role: "assistant", content: "", task_id: owner.history.to_a.last[:task_id],
                             tool_calls: owner.send(:format_tool_calls_for_api, [call]))
        action = owner.send(:act, [call])
        owner.send(:observe, response, action[:tool_results])
        { action: :handled, result: owner.send(:build_result, awaiting_user_feedback: action[:awaiting_feedback])
                                        .merge(queue_paused: true) }
      end

      2.times do |index|
        input = index.zero? ? "request" : "Review again"
        expect(agent.run(input)[:awaiting_user_feedback]).to be(true)
      end
      expect(agent).not_to have_received(:think)
      expect(events.count { |event| event[:type] == "request_feedback" }).to eq(2)
      expect(tool_hooks).to eq(%w[ask_user ask_user])
      replayed = []
      agent.replay_history(Clacky::Server::HistoryCollector.new(session_id, replayed), limit: 30)
      expect(replayed.count { |event| event[:type] == "request_feedback" }).to eq(2)
      expect(agent.run("Confirm")[:awaiting_user_feedback]).to be(false)
      expect(agent).to have_received(:think).once
      expect(user_messages.map { |message| message[:content] }).to eq(["request", "Review again", "Confirm"])
      expect(agent.total_tasks).to eq(3)
    end
  end
end
