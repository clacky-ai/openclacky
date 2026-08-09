# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Agent, "#fan_out_subagents" do
  let(:client) { instance_double(Clacky::Client) }
  let(:config) { Clacky::AgentConfig.new }

  let(:agent) do
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.pwd, ui: nil, profile: "coding",
      session_id: Clacky::SessionManager.generate_id, source: :manual
    )
  end

  # A stand-in for a forked subagent: records the task it ran and exposes a
  # history shaped like the real one so final_assistant_text can read it.
  def fake_subagent(reply:, cost: 0.0, delay: 0.0, &on_run)
    subagent = instance_double(Clacky::Agent)
    history = instance_double(Clacky::MessageHistory)
    messages = [{ role: "assistant", content: reply }]

    allow(history).to receive(:to_a).and_return(messages)
    allow(subagent).to receive(:history).and_return(history)
    allow(subagent).to receive(:instance_variable_set)
    allow(subagent).to receive(:instance_variable_get).with(:@parent_message_count).and_return(0)
    allow(subagent).to receive(:run) do |task|
      on_run&.call(task)
      sleep delay if delay.positive?
      { total_cost_usd: cost }
    end
    subagent
  end

  it "returns an empty array when there are no tasks" do
    expect(agent.fan_out_subagents([])).to eq([])
  end

  it "returns each subagent's final reply in task order" do
    allow(agent).to receive(:fork_subagent).and_return(
      fake_subagent(reply: "first", delay: 0.1),
      fake_subagent(reply: "second"),
      fake_subagent(reply: "third", delay: 0.05)
    )

    results = agent.fan_out_subagents(%w[a b c], max_concurrency: 3)

    expect(results.map(&:value)).to eq(%w[first second third])
    expect(results).to all(be_ok)
  end

  it "gives each subagent its own task" do
    seen = Queue.new
    allow(agent).to receive(:fork_subagent) do
      fake_subagent(reply: "ok") { |task| seen << task }
    end

    agent.fan_out_subagents(%w[alpha beta], max_concurrency: 2)

    expect(Array.new(seen.size) { seen.pop }.sort).to eq(%w[alpha beta])
  end

  it "accumulates the cost of every subagent into the parent" do
    allow(agent).to receive(:fork_subagent).and_return(
      fake_subagent(reply: "a", cost: 0.10),
      fake_subagent(reply: "b", cost: 0.25)
    )

    agent.fan_out_subagents(%w[a b], max_concurrency: 2)

    expect(agent.total_cost).to be_within(1e-9).of(0.35)
  end

  it "wraps each subagent in its own labelled UI phase instead of silencing it" do
    ui = instance_double(Clacky::Server::WebUIController)
    phases = []
    allow(ui).to receive(:with_phase) do |kind:, label:, concurrent: false, &block|
      phases << [kind, label, concurrent]
      block.call
    end
    agent.instance_variable_set(:@ui, ui)
    allow(agent).to receive(:fork_subagent) { fake_subagent(reply: "loud") }

    agent.fan_out_subagents(%w[a b])

    expect(phases).to eq([["fanout_subagent", "Subagent 1/2", true], ["fanout_subagent", "Subagent 2/2", true]])
  end

  it "forks on the calling thread, before any subagent runs" do
    running = false
    fork_during_run = false

    allow(agent).to receive(:fork_subagent) do
      fork_during_run = true if running
      fake_subagent(reply: "ok", delay: 0.05) { running = true }
    end

    agent.fan_out_subagents(%w[a b c], max_concurrency: 3)

    expect(fork_during_run).to be(false)
  end

  it "keeps siblings alive when one subagent raises" do
    exploding = instance_double(Clacky::Agent)
    allow(exploding).to receive(:instance_variable_set)
    allow(exploding).to receive(:instance_variable_get).and_return(0)
    allow(exploding).to receive(:run).and_raise(Clacky::AgentError, "subagent died")

    allow(agent).to receive(:fork_subagent).and_return(
      fake_subagent(reply: "survivor one"),
      exploding,
      fake_subagent(reply: "survivor two")
    )

    results = agent.fan_out_subagents(%w[a b c], max_concurrency: 3)

    expect(results[0].value).to eq("survivor one")
    expect(results[2].value).to eq("survivor two")
    expect(results[1]).not_to be_ok
    expect(results[1].error).to be_a(Clacky::AgentError)
  end

  it "marks a subagent that overruns the batch budget as timed out" do
    allow(agent).to receive(:fork_subagent).and_return(
      fake_subagent(reply: "quick"),
      fake_subagent(reply: "slow", delay: 5)
    )

    results = agent.fan_out_subagents(%w[a b], max_concurrency: 2, timeout: 0.3)

    expect(results[0].value).to eq("quick")
    expect(results[1].error).to be_a(Clacky::FanoutTimeoutError)
  end

  it "honours the concurrency limit" do
    peak = 0
    active = 0
    lock = Mutex.new

    allow(agent).to receive(:fork_subagent) do
      subagent = instance_double(Clacky::Agent)
      history = instance_double(Clacky::MessageHistory)
      allow(history).to receive(:to_a).and_return([{ role: "assistant", content: "ok" }])
      allow(subagent).to receive(:history).and_return(history)
      allow(subagent).to receive(:instance_variable_set)
      allow(subagent).to receive(:instance_variable_get).and_return(0)
      allow(subagent).to receive(:run) do
        lock.synchronize do
          active += 1
          peak = [peak, active].max
        end
        sleep 0.05
        lock.synchronize { active -= 1 }
        { total_cost_usd: 0.0 }
      end
      subagent
    end

    agent.fan_out_subagents(%w[a b c d e f], max_concurrency: 2)

    expect(peak).to eq(2)
  end

  it "passes model and forbidden tools through to every fork" do
    allow(agent).to receive(:fork_subagent).and_return(fake_subagent(reply: "ok"))

    agent.fan_out_subagents(["a"], model: "lite", forbidden_tools: ["terminal"])

    expect(agent).to have_received(:fork_subagent).with(
      hash_including(model: "lite", forbidden_tools: ["terminal"])
    )
  end
end
