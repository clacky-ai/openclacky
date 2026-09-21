# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Agent, "before_user_message hook" do
  let(:config) { Clacky::AgentConfig.new(memory_update_enabled: false, skill_evolution: { enabled: false }) }
  let(:client) { double("client", current_model: nil) }
  let(:ui) { double("ui").as_null_object }
  let(:agent) do
    described_class.new(client, config, working_dir: Dir.pwd, ui: ui, profile: "coding",
                         session_id: Clacky::SessionManager.generate_id, source: :web)
  end

  before do
    allow(agent).to receive(:think).and_return({ content: "done", tool_calls: [] })
    allow(agent).to receive(:run_skill_evolution_hooks)
    allow(agent).to receive(:run_memory_update_subagent)
  end

  it "passes the mutable message and owning agent through the existing hook chain" do
    agent.add_hook(:before_user_message) do |message, owner|
      expect(owner).to equal(agent)
      expect(message).to include(content: "original", reference_contexts: ["reference"])
      expect(owner.history.to_a).to be_empty
      message[:display_text] = message[:content]
      message[:content] = "rewritten"
      { action: :allow }
    end
    agent.add_hook(:before_user_message) do |message|
      expect(message[:content]).to eq("rewritten")
      nil
    end

    agent.run("original", reference_contexts: ["reference"])

    user_message = agent.history.to_a.find { |message| message[:display_text] == "original" }
    expect(user_message).to include(content: "rewritten")
    expect(agent).to have_received(:think).once
  end

  it "retains the existing fail-open behavior when a hook raises" do
    agent.add_hook(:before_user_message) { raise "hook failed" }
    agent.add_hook(:before_user_message) { |message| message[:content] = "recovered" }

    expect(agent.run("original")[:status]).to eq(:success)
    expect(agent.history.to_api.map { |message| message[:content] }).to include("recovered")
  end

  it "denies before attachments, history and lifecycle work, including on the next allowed turn" do
    lifecycle = []
    agent.add_hook(:on_start) { lifecycle << :start }
    agent.add_hook(:on_complete) { lifecycle << :complete }
    agent.add_hook(:before_user_message) do |message|
      { action: :deny, reason: "blocked by policy" } if message[:content] == "blocked"
    end
    expect(Clacky::Utils::FileProcessor).not_to receive(:process_path)

    result = agent.run("blocked", files: [{ path: __FILE__, name: "policy.txt" }],
                                  reference_contexts: ["blocked reference"])

    expect(result).to eq(status: :success, queue_paused: true)
    expect(agent.history.to_a).to be_empty
    expect(agent.total_tasks).to eq(0)
    expect(lifecycle).to be_empty
    expect(agent).not_to have_received(:think)
    expect(agent).not_to have_received(:run_memory_update_subagent)
    expect(agent).not_to have_received(:run_skill_evolution_hooks)
    expect(ui).not_to have_received(:show_complete)
    expect(ui).to have_received(:show_warning).with("blocked by policy")

    agent.run("allowed")

    user_messages = agent.history.to_api.select { |message| message[:role] == "user" }
    expect(user_messages.map { |message| message[:content] }).not_to include("blocked", "blocked reference")
    expect(user_messages.to_s).not_to include("policy.txt")
    expect(agent).to have_received(:think).once
    expect(lifecycle).to eq(%i[start complete])
  end

  it "checks goal commands before they can change goal state" do
    agent.add_hook(:before_user_message) { { action: :deny } }
    expect(agent).not_to receive(:handle_goal_command)

    expect(agent.run("/goal do something")[:queue_paused]).to be(true)
  end

  it "returns a handled result unchanged without default processing or later hooks" do
    replacement = { status: :success, queue_paused: true, awaiting_user_feedback: true }.freeze
    agent.add_hook(:before_user_message) { { action: :handled, result: replacement } }
    agent.add_hook(:before_user_message) { raise RSpec::Expectations::ExpectationNotMetError, "later hook ran" }
    expect(agent).not_to receive(:append_user_input)
    expect(agent).not_to receive(:maybe_continue_goal)
    lifecycle = []
    agent.add_hook(:on_start) { lifecycle << :start }
    agent.add_hook(:on_complete) { lifecycle << :complete }

    expect(agent.run("handled")).to equal(replacement)
    expect(agent.history.to_a).to be_empty
    expect(agent).not_to have_received(:think)
    expect(lifecycle).to be_empty
    expect(ui).not_to have_received(:show_complete)
  end

  it "checks queued input exactly once and leaves subsequent tasks pending on deny" do
    seen = []
    agent.add_hook(:before_user_message) do |message|
      seen << message[:content]
      { action: :deny }
    end
    agent.enqueue_input("queued")
    agent.enqueue_input("later")

    result = agent.run_pending_input(agent.take_pending_input)

    expect(seen).to eq(["queued"])
    expect(described_class.task_completed?(result)).to be(false)
    expect(agent.pending_inputs.map { |entry| entry[:content] }).to eq(["later"])
    expect(agent.history.to_a).to be_empty
    expect(agent).not_to have_received(:think)
  end

  %i[deny handled].each do |action|
    %i[tool_result final_response].each do |arrival|
      it "stops on #{action} steering after a #{arrival} and preserves later guidance" do
        replacement = { status: :success, awaiting_user_feedback: true, queue_paused: true }.freeze
        agent.add_hook(:before_user_message) do |message|
          { action: action, result: replacement } if message[:content] == "blocked guidance"
        end
        completed = false
        agent.add_hook(:on_complete) { completed = true }
        enqueue = lambda do
          agent.enqueue_input("blocked guidance", delivery: :steer)
          agent.enqueue_input("later guidance", delivery: :steer)
        end
        if arrival == :tool_result
          allow(agent).to receive(:think).and_return(
            { content: nil, tool_calls: [{ id: "call-1", name: "read", arguments: {} }] }
          )
          allow(agent).to receive(:act) do
            enqueue.call
            { tool_results: [] }
          end
          allow(agent).to receive(:observe)
        else
          allow(agent).to receive(:think) do
            enqueue.call
            { content: "done", tool_calls: [] }
          end
        end
        expect(agent).not_to receive(:maybe_continue_goal)

        result = agent.run("original task")

        expect(result[:queue_paused]).to be(true)
        expect(result).to equal(replacement) if action == :handled
        expect(agent).to have_received(:think).once
        expect(agent.history.to_api.to_s).not_to include("blocked guidance", "later guidance")
        expect(agent.pending_inputs).to contain_exactly(hash_including(content: "later guidance", delivery: "queue"))
        expect(agent.instance_variable_get(:@accepting_steering)).to be(false)
        expect(completed).to be(false)
        expect(agent).not_to have_received(:run_memory_update_subagent)
        expect(agent).not_to have_received(:run_skill_evolution_hooks)
      end
    end
  end

  it "does not duplicate unprocessed guidance if publishing the restored queue fails" do
    agent.instance_variable_set(:@accepting_steering, true)
    agent.enqueue_input("blocked", delivery: :steer)
    agent.enqueue_input("later", delivery: :steer)
    agent.add_hook(:before_user_message) { { action: :deny } }
    allow(agent).to receive(:notify_input_queue).and_raise("UI disconnected")

    expect { agent.send(:consume_steering_inputs) }.to raise_error("UI disconnected")
    expect(agent.pending_inputs.map { |entry| entry[:content] }).to eq(["later"])
  end

  it "applies steering rewrites without stripping fields from the hook's message object" do
    seen = nil
    agent.add_hook(:before_user_message) do |message|
      next unless message[:content] == "guidance"

      seen = message
      message[:content] = "rewritten guidance"
      message[:reference_contexts] = ["rewritten reference"]
      message[:annotation] = "extension data"
      { action: :allow }
    end
    calls = 0
    allow(agent).to receive(:think) do
      calls += 1
      agent.enqueue_input("guidance", delivery: :steer) if calls == 1
      { content: "done", tool_calls: [] }
    end

    agent.run("task")

    expect(seen).to include(content: "rewritten guidance", annotation: "extension data")
    expect(agent.history.to_api.map { |message| message[:content] }).to include(
      "rewritten guidance", "rewritten reference"
    )
    expect(agent).to have_received(:think).twice
  end

  it "lets an extension own repeated feedback and release its saved message on confirmation" do
    pending = nil
    agent.add_hook(:before_user_message) do |message, owner|
      if pending && message[:content] == "Confirm"
        message[:content] = pending
        pending = nil
        next { action: :allow }
      end

      pending ||= message[:content]
      owner.ui.show_tool_call("ask_user", question: "Continue?", options: ["Confirm", "Review again"])
      { action: :handled, result: { status: :success, awaiting_user_feedback: true, queue_paused: true } }
    end

    expect(agent.run("needs confirmation")[:awaiting_user_feedback]).to be(true)
    expect(agent.run("Review again")[:awaiting_user_feedback]).to be(true)
    expect(agent.history.to_a).to be_empty
    expect(agent).not_to have_received(:think)
    expect(agent.run("Confirm")[:awaiting_user_feedback]).to be(false)
    expect(agent).to have_received(:think).once
    expect(ui).to have_received(:show_tool_call).with("ask_user", any_args).twice
    expect(agent.history.to_api.map { |message| message[:content] }).to include("needs confirmation")
  end
end
