# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent time machine session restore" do
  let(:client) { instance_double(Clacky::Client) }
  let(:config) { Clacky::AgentConfig.new }
  let(:agent) do
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.pwd, ui: nil, profile: "coding",
      session_id: Clacky::SessionManager.generate_id, source: :manual,
    )
  end

  it "restores task_parents with Integer keys/values from JSON-symbolized hashes" do
    serialized_parents = { :"1" => 0, :"2" => 1, :"3" => 2 }

    agent.restore_session(
      session_id: agent.session_id, working_dir: Dir.pwd,
      messages: [], todos: [], stats: {}, config: {},
      time_machine: {
        task_parents: serialized_parents,
        current_task_id: 3,
        active_task_id: 3,
      },
    )

    parents = agent.instance_variable_get(:@task_parents)
    expect(parents).to eq(1 => 0, 2 => 1, 3 => 2)
    expect(parents.keys).to all(be_an(Integer))
    expect(parents.values).to all(be_an(Integer))
    expect(agent.instance_variable_get(:@current_task_id)).to eq(3)
    expect(agent.instance_variable_get(:@active_task_id)).to eq(3)
  end

  it "marks the full ancestor chain as :past after a JSON round trip" do
    saved = {
      session_id: agent.session_id,
      working_dir: Dir.pwd,
      messages: [
        { role: "user", content: "first",  task_id: 1, created_at: 1.0 },
        { role: "user", content: "second", task_id: 2, created_at: 2.0 },
        { role: "user", content: "third",  task_id: 3, created_at: 3.0 },
      ],
      todos: [], stats: {}, config: {},
      time_machine: {
        task_parents: { 1 => 0, 2 => 1, 3 => 2 },
        current_task_id: 3,
        active_task_id: 3,
      },
    }
    round_tripped = JSON.parse(JSON.generate(saved), symbolize_names: true)

    agent.restore_session(round_tripped)

    history = agent.get_task_history(limit: 10)
    by_id = history.each_with_object({}) { |t, h| h[t[:task_id]] = t }
    expect(by_id[3][:status]).to eq(:current)
    expect(by_id[2][:status]).to eq(:past)
    expect(by_id[1][:status]).to eq(:past)
  end

  it "shows all tasks but uses placeholder for ones whose user message was compressed out" do
    agent.restore_session(
      session_id: agent.session_id, working_dir: Dir.pwd,
      messages: [
        { role: "user", content: "kept turn", task_id: 80, created_at: 1.0 },
      ],
      todos: [], stats: {}, config: {},
      time_machine: {
        task_parents: (1..80).each_with_object({}) { |i, h| h[i] = i - 1 },
        current_task_id: 80,
        active_task_id: 80,
      },
    )

    history = agent.get_task_history(limit: 5)
    expect(history.map { |t| t[:task_id] }).to eq([76, 77, 78, 79, 80])
    by_id = history.each_with_object({}) { |t, h| h[t[:task_id]] = t }
    expect(by_id[80][:summary]).to eq("kept turn")
    expect(by_id[79][:summary]).to eq("Task 79")
    expect(by_id[80][:status]).to eq(:current)
  end

  it "ignores system_injected user messages when picking the task summary" do
    agent.restore_session(
      session_id: agent.session_id, working_dir: Dir.pwd,
      messages: [
        { role: "user", content: "[file] some.pdf", task_id: 1, system_injected: true, created_at: 0.5 },
        { role: "user", content: "real turn",       task_id: 1, created_at: 1.0 },
      ],
      todos: [], stats: {}, config: {},
      time_machine: { task_parents: { 1 => 0 }, current_task_id: 1, active_task_id: 1 },
    )

    history = agent.get_task_history(limit: 5)
    expect(history.first[:summary]).to eq("real turn")
  end

  it "prefers task_meta.title over scanning history" do
    agent.restore_session(
      session_id: agent.session_id, working_dir: Dir.pwd,
      messages: [
        { role: "user", content: "raw text in history", task_id: 1, created_at: 1.0 },
      ],
      todos: [], stats: {}, config: {},
      time_machine: {
        task_parents: { 1 => 0 },
        current_task_id: 1,
        active_task_id: 1,
        task_meta: { 1 => { title: "explicit title", started_at: 1.0, ended_at: 2.0 } },
      },
    )

    history = agent.get_task_history(limit: 5)
    expect(history.first[:summary]).to eq("explicit title")
    expect(history.first[:started_at]).to eq(1.0)
  end

  it "backfills task_meta from history for sessions saved before task_meta existed" do
    agent.restore_session(
      session_id: agent.session_id, working_dir: Dir.pwd,
      messages: [
        { role: "user",      content: "first turn",  task_id: 1, created_at: 1.0 },
        { role: "assistant", content: "first reply", task_id: 1, created_at: 1.5 },
        { role: "user",      content: "second turn", task_id: 2, created_at: 2.0 },
      ],
      todos: [], stats: {}, config: {},
      time_machine: { task_parents: { 1 => 0, 2 => 1 }, current_task_id: 2, active_task_id: 2 },
    )

    meta = agent.instance_variable_get(:@task_meta)
    expect(meta[1][:title]).to eq("first turn")
    expect(meta[1][:started_at]).to eq(1.0)
    expect(meta[1][:ended_at]).to eq(1.5)
    expect(meta[2][:title]).to eq("second turn")
    expect(meta[2][:started_at]).to eq(2.0)
  end

  it "persists task_meta with Integer keys after a JSON round trip" do
    agent.start_new_task(title: "build feature X")
    saved = agent.to_session_data(status: :success)
    parsed = JSON.parse(JSON.generate(saved), symbolize_names: true)

    agent.instance_variable_set(:@task_meta, {})
    agent.restore_session(parsed)

    meta = agent.instance_variable_get(:@task_meta)
    expect(meta.keys).to all(be_an(Integer))
    expect(meta[1][:title]).to eq("build feature X")
    expect(meta[1][:started_at]).to be_a(Float)
  end

  it "computes diff for the latest task after a process restart (latest_after_dirty defaults safely)" do
    Dir.mktmpdir do |work|
      file = File.join(work, "f.txt")
      a = Clacky::Agent.new(
        client, config,
        working_dir: work, ui: nil, profile: "coding",
        session_id: Clacky::SessionManager.generate_id, source: :manual,
      )
      a.start_new_task(title: "t1")
      a.record_file_before_change(file)
      File.write(file, "v1")
      a.start_new_task(title: "t2")
      a.record_file_before_change(file)
      File.write(file, "v2")
      a.undo_last_task
      saved = JSON.parse(JSON.generate(a.to_session_data(status: :success)), symbolize_names: true)

      restored = Clacky::Agent.new(
        client, config,
        working_dir: work, ui: nil, profile: "coding",
        session_id: a.session_id, source: :manual,
      )
      restored.restore_session(saved)

      expect(restored.instance_variable_get(:@latest_after_dirty)).to eq(true)
      expect(restored.task_change_count(2)).to be > 0
      expect(restored.task_diff_files(2)).not_to be_empty
    ensure
      Clacky::Agent::TimeMachine.delete_session_snapshots(a.session_id) if defined?(a) && a
    end
  end
end
