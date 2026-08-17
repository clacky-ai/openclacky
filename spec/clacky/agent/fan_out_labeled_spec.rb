# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Agent, "#fan_out_labeled" do
  let(:client) { instance_double(Clacky::Client) }
  let(:config) { Clacky::AgentConfig.new }

  let(:agent) do
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.pwd, ui: nil, profile: "coding",
      session_id: Clacky::SessionManager.generate_id, source: :manual
    )
  end

  it "returns an empty array when there are no jobs" do
    expect(agent.fan_out_labeled([])).to eq([])
  end

  it "keeps results aligned to input order regardless of completion order" do
    jobs = [
      { label: "slow", run: -> { sleep 0.1; "first" } },
      { label: "fast", run: -> { "second" } }
    ]

    results = agent.fan_out_labeled(jobs, max_concurrency: 2)

    expect(results.map(&:value)).to eq(%w[first second])
    expect(results).to all(be_ok)
  end

  it "isolates a failing job from its siblings" do
    jobs = [
      { label: "ok", run: -> { "fine" } },
      { label: "boom", run: -> { raise "nope" } }
    ]

    results = agent.fan_out_labeled(jobs, max_concurrency: 2)

    expect(results[0]).to be_ok
    expect(results[1]).not_to be_ok
    expect(results[1].error.message).to eq("nope")
  end

  it "opens a concurrent UI phase per job, labeled by the caller" do
    ui = instance_double(Clacky::UI2::UIController)
    seen = Queue.new
    allow(ui).to receive(:with_phase) do |kind:, label:, concurrent:, &block|
      seen << { kind: kind, label: label, concurrent: concurrent }
      block.call
    end
    agent.instance_variable_set(:@ui, ui)

    jobs = [{ label: "code-explorer", run: -> { "a" } }, { label: "media-gen", run: -> { "b" } }]
    agent.fan_out_labeled(jobs, max_concurrency: 2)

    phases = Array.new(seen.size) { seen.pop }
    expect(phases.map { |p| p[:label] }.sort).to eq(["code-explorer", "media-gen"])
    expect(phases).to all(include(kind: "fanout_subagent", concurrent: true))
  end

  it "falls back to a positional label when the caller omits one" do
    ui = instance_double(Clacky::UI2::UIController)
    labels = Queue.new
    allow(ui).to receive(:with_phase) do |label:, **_rest, &block|
      labels << label
      block.call
    end
    agent.instance_variable_set(:@ui, ui)

    agent.fan_out_labeled([{ run: -> { "x" } }, { run: -> { "y" } }], max_concurrency: 2)

    expect(Array.new(labels.size) { labels.pop }.sort).to eq(["Subagent 1/2", "Subagent 2/2"])
  end

  it "rejects a job without a callable :run" do
    expect { agent.fan_out_labeled([{ label: "bad" }]) }
      .to raise_error(ArgumentError, /callable :run/)
  end

  it "carries the task epoch into worker threads" do
    Thread.current[:task_epoch] = 42
    seen = Queue.new
    agent.fan_out_labeled([{ label: "a", run: -> { seen << Thread.current[:task_epoch] } }])

    expect(seen.pop).to eq(42)
  ensure
    Thread.current[:task_epoch] = nil
  end

  it "honours max_concurrency" do
    running = 0
    peak = 0
    mutex = Mutex.new
    jobs = Array.new(6) do
      { label: "j", run: lambda do
        mutex.synchronize { running += 1; peak = [peak, running].max }
        sleep 0.05
        mutex.synchronize { running -= 1 }
      end }
    end

    agent.fan_out_labeled(jobs, max_concurrency: 2)

    expect(peak).to be <= 2
  end
end
