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
      agent.enqueue_input("Only change the backend", reference_contexts: ["Reference context"])
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
      agent.enqueue_input("Also explain it") if count == 1
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
    agent.send(:consume_pending_inputs)
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
    agent.enqueue_input("first")
    agent.enqueue_input("second")
    allow(agent).to receive(:append_user_input).and_raise("parsing failed")
    expect { agent.send(:consume_pending_inputs) }.to raise_error("parsing failed")
    expect(agent.pending_inputs.map { |m| m[:content] }).to eq(%w[first second])
  end
end

RSpec.describe Clacky::AgentConfig, "input behavior" do
  it "preserves interruption by default and normalizes unknown values" do
    expect(described_class.new.input_behavior).to eq("interrupt")
    expect(described_class.new(input_behavior: "unknown").input_behavior).to eq("interrupt")
  end

  it "persists the opt-in setting" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      described_class.new(input_behavior: "steer").save(path)
      expect(described_class.load(path).input_behavior).to eq("steer")
    end
  end
end
