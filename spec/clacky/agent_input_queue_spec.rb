# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Agent, "queued guidance" do
  let(:config) { Clacky::AgentConfig.new(memory_update_enabled: false, skill_evolution: { enabled: false }) }
  let(:client) { double("client", current_model: nil) }
  let(:agent) do
    described_class.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding",
                         session_id: Clacky::SessionManager.generate_id, source: :manual)
  end

  before do
    allow(agent).to receive(:think).and_return({ content: "done", tool_calls: [] })
    allow(agent).to receive(:run_skill_evolution_hooks)
    allow(agent).to receive(:run_memory_update_subagent)
  end

  it "consumes guidance after tool results without starting another task" do
    responses = [
      { content: nil, tool_calls: [{ id: "call-1", name: "read", arguments: {} }] },
      { content: "done", tool_calls: [] }
    ]
    allow(agent).to receive(:think) { responses.shift }
    allow(agent).to receive(:act) do
      agent.enqueue_input("Only change the backend", delivery: :steer, reference_contexts: ["Reference context"])
      { tool_results: [{ id: "call-1", content: "file content" }] }
    end
    allow(agent).to receive(:observe) do
      agent.history.append(role: "tool", tool_call_id: "call-1", content: "file content")
    end
    agent.run("Inspect the project")
    messages = agent.history.to_a
    tool_index = messages.index { |m| m[:tool_call_id] == "call-1" }
    guidance_index = messages.index { |m| m[:content] == "Only change the backend" }
    expect(guidance_index).to be > tool_index
    expect(messages[guidance_index + 1][:content]).to eq("Reference context")
    expect(agent.total_tasks).to eq(1)
    expect(agent.pending_inputs).to be_empty
  end

  it "checks messages arriving during a final response before finishing" do
    count = 0
    allow(agent).to receive(:think) do
      count += 1
      agent.enqueue_input("Also explain it", delivery: :steer) if count == 1
      { content: "done", tool_calls: [] }
    end
    agent.run("First request")
    expect(count).to eq(2)
    expect(agent.total_tasks).to eq(1)
  end

  it "edits and removes only pending entries, preserving files and FIFO order" do
    first = agent.enqueue_input("first", files: [{ name: "note.txt", path: "/tmp/note.txt" }])
    second = agent.enqueue_input("second")
    expect(agent.edit_pending_input(first, "updated")).to be(true)
    agent.remove_pending_input(second)
    expect(agent.pending_inputs.first).to include(id: first, content: "updated")
    expect(agent.pending_inputs.first[:options][:files].first[:name]).to eq("note.txt")
    agent.take_pending_input
    expect(agent.edit_pending_input(first, "too late")).to be(false)
    expect(agent.pending_inputs).to be_empty
  end

  it "retains unconsumed input when execution is explicitly interrupted" do
    allow(agent).to receive(:think) do
      agent.enqueue_input("pending")
      raise Clacky::AgentInterrupted
    end
    expect { agent.run("work") }.to raise_error(Clacky::AgentInterrupted)
    expect(agent.pending_inputs.map { |m| m[:content] }).to eq(["pending"])
    expect(agent.to_session_data[:pending_inputs].first[:content]).to eq("pending")
  end

  it "restores a failed batch in FIFO order" do
    agent.instance_variable_set(:@accepting_steering, true)
    agent.enqueue_input("first", delivery: :steer)
    agent.enqueue_input("second", delivery: :steer)
    allow(agent).to receive(:append_user_input).and_raise("parsing failed")
    expect { agent.send(:consume_steering_inputs) }.to raise_error("parsing failed")
    expect(agent.pending_inputs.map { |m| m[:content] }).to eq(%w[first second])
  end

  it "keeps ordinary queued tasks out of the active task, including its final response" do
    allow(agent).to receive(:think) do
      agent.enqueue_input("write tests")
      agent.enqueue_input("update docs")
      { content: "implementation done", tool_calls: [] }
    end
    agent.run("implement login")
    expect(agent.pending_inputs.map { |entry| entry[:content] }).to eq(["write tests", "update docs"])
    expect(agent.history.to_a.none? { |message| message[:content] == "write tests" }).to be(true)
    expect(agent.total_tasks).to eq(1)
    allow(agent).to receive(:think).and_return({ content: "done", tool_calls: [] })
    agent.run_pending_input(agent.take_pending_input)
    expect(agent.pending_inputs.map { |entry| entry[:content] }).to eq(["update docs"])
    expect(agent.total_tasks).to eq(2)
  end

  it "promotes only the selected message while preserving files and the remaining order" do
    first = agent.enqueue_input("later one")
    selected = agent.enqueue_input("use phone login", reference_contexts: ["reference"])
    last = agent.enqueue_input("later two")
    calls = 0
    allow(agent).to receive(:think) do
      calls += 1
      if calls == 1
        target = agent.pending_inputs.first[:steer_target]
        expect(agent.steer_pending_input(selected, expected_task_id: target)).to be(true)
      end
      { content: "done", tool_calls: [] }
    end
    agent.run("login")
    expect(calls).to eq(2)
    expect(agent.total_tasks).to eq(1)
    expect(agent.pending_inputs.map { |entry| entry[:id] }).to eq([first, last])
    expect(agent.history.to_a.map { |message| message[:content] }).to include("use phone login", "reference")
  end

  it "rejects stale task targets without moving or consuming the queued entry" do
    id = agent.enqueue_input("later")
    old_target = nil
    allow(agent).to receive(:think) do
      old_target = agent.pending_inputs.first[:steer_target]
      { content: "done", tool_calls: [] }
    end
    agent.run("first")
    expect(agent.steer_pending_input(id, expected_task_id: old_target)).to be(false)
    allow(agent).to receive(:think) do
      expect(agent.steer_pending_input(id, expected_task_id: old_target)).to be(false)
      { content: "done", tool_calls: [] }
    end
    agent.run("second")
    expect(agent.pending_inputs.map { |entry| entry[:id] }).to eq([id])
  end

  it "closes guidance before memory and completion hooks run" do
    id = agent.enqueue_input("later")
    target = nil
    allow(agent).to receive(:think) do
      target = agent.pending_inputs.first[:steer_target]
      { content: "done", tool_calls: [] }
    end
    expect(agent).to receive(:run_memory_update_subagent) do
      expect(agent.steer_pending_input(id, expected_task_id: target)).to be(false)
      agent.enqueue_input("late steer", delivery: :steer)
    end
    agent.run("first")
    expect(agent.pending_inputs.map { |entry| entry[:delivery] }).to eq(%w[queue queue])
  end

  it "does not close the task while an accepted guidance message is pending" do
    agent.instance_variable_set(:@accepting_steering, true)
    id = agent.enqueue_input("guidance")
    expect(agent.steer_pending_input(id, expected_task_id: agent.pending_inputs.first[:steer_target])).to be(true)
    expect(agent.send(:consume_steering_inputs, finishing: true)).to be(true)
    expect(agent.instance_variable_get(:@accepting_steering)).to be(true)
    expect(agent.send(:consume_steering_inputs, finishing: true)).to be(false)
    expect(agent.instance_variable_get(:@accepting_steering)).to be(false)
  end

  it "never promotes slash commands into the middle of a task" do
    agent.instance_variable_set(:@accepting_steering, true)
    id = agent.enqueue_input("/goal another task")
    expect(agent.steer_pending_input(id, expected_task_id: agent.pending_inputs.first[:steer_target])).to be(false)
    expect(agent.pending_inputs.first[:delivery]).to eq("queue")
  end

  it "pauses the queue and goal continuation when user feedback is required" do
    agent.enqueue_input("unrelated task")
    allow(agent).to receive(:think).and_return({ content: nil, tool_calls: [{ id: "ask", name: "ask_user", arguments: {} }] })
    allow(agent).to receive(:act).and_return({ awaiting_feedback: true, tool_results: [] })
    allow(agent).to receive(:observe)
    expect(agent).not_to receive(:maybe_continue_goal)
    result = agent.run("needs an answer")
    expect(result).to include(awaiting_user_feedback: true, queue_paused: true)
    expect(agent.pending_inputs.size).to eq(1)
  end

  it "restores pending guidance as a queued task after a session restart" do
    agent.instance_variable_set(:@accepting_steering, true)
    agent.enqueue_input("later", delivery: :steer)
    agent.restore_session(agent.to_session_data)
    expect(agent.pending_inputs.first).to include(delivery: "queue", steer_target: nil)
  end

  it "restores a rejected immediate task at its original position with its identity intact" do
    ids = %w[first second third].map { |text| agent.enqueue_input(text) }
    entry = agent.remove_pending_input(ids[1], for_execution: true)
    agent.restore_pending_input(entry)
    expect(agent.pending_inputs.map { |item| item[:id] }).to eq(ids)
  end

  it "does not pause queued work merely because a completed answer ends in a question" do
    allow(agent).to receive(:think).and_return({ content: "Done. Anything else?", tool_calls: [] })
    expect(agent.run("task")[:queue_paused]).not_to be(true)
  end

  it "keeps queued tasks across automatic goal continuation" do
    agent.enqueue_input("next task")
    continuations = 0
    allow(agent).to receive(:maybe_continue_goal) do
      continuations += 1
      continuations == 1 ? agent.run("continue goal") : nil
    end
    agent.run("work on goal")
    expect(agent.total_tasks).to eq(2)
    expect(agent.pending_inputs.first[:content]).to eq("next task")
    expect(agent.history.to_a.none? { |message| message[:content] == "next task" }).to be(true)
  end

  it "pauses the queue when the goal budget is exhausted" do
    state = double("goal state", paused?: true)
    allow(agent).to receive(:maybe_continue_goal) do
      agent.instance_variable_set(:@goal_manager, double("manager", state: state))
      nil
    end
    expect(agent.run("task")[:queue_paused]).to be(true)
  end

end

RSpec.describe Clacky::AgentConfig, "input behavior" do
  it "queues by default and normalizes unknown values" do
    expect(described_class.new.input_behavior).to eq("queue")
    expect(described_class.new(input_behavior: "unknown").input_behavior).to eq("queue")
  end

  it "persists the opt-in setting" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      described_class.new(input_behavior: "steer").save(path)
      expect(described_class.load(path).input_behavior).to eq("steer")
    end
  end
end
