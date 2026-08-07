# frozen_string_literal: true

require "spec_helper"
require "time"

RSpec.describe "Agent updated_at preservation (fail-safe default)" do
  let(:client) { instance_double(Clacky::Client) }
  let(:config) { Clacky::AgentConfig.new }
  let(:session_id) { Clacky::SessionManager.generate_id }
  let(:frozen_time) { "2026-08-05T06:25:15+08:00" }

  let(:agent) do
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.pwd, ui: nil, profile: "coding",
      session_id: session_id, source: :manual,
    )
  end

  def round_trip(data)
    JSON.parse(JSON.generate(data), symbolize_names: true)
  end

  def new_agent(sid = session_id)
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.pwd, ui: nil, profile: "coding",
      session_id: sid, source: :manual,
    )
  end

  it "preserves the persisted updated_at when no updated_at is passed (no-content touch)" do
    saved = round_trip(agent.to_session_data(updated_at: Time.now))
    saved[:updated_at] = frozen_time

    restored = new_agent
    restored.restore_session(saved)

    expect(restored.to_session_data[:updated_at]).to eq(frozen_time)
  end

  it "refreshes updated_at when updated_at: Time.now is passed (write operation)" do
    saved = round_trip(agent.to_session_data(updated_at: Time.now))
    saved[:updated_at] = frozen_time

    restored = new_agent
    restored.restore_session(saved)

    before = Time.now
    data = restored.to_session_data(updated_at: Time.now)
    expect(Time.parse(data[:updated_at])).to be_within(2).of(before)
  end

  it "does not change disk updated_at across save->load->restore->save with no content change" do
    Dir.mktmpdir do |dir|
      sm = Clacky::SessionManager.new(sessions_dir: dir)

      sm.save(agent.to_session_data(updated_at: Time.now))

      disk = round_trip(sm.load(session_id))
      original_updated_at = disk[:updated_at]
      expect(original_updated_at).not_to be_nil

      restored = new_agent
      restored.restore_session(disk)

      sleep 0.01
      sm.save(restored.to_session_data)

      disk2 = round_trip(sm.load(session_id))
      expect(disk2[:updated_at]).to eq(original_updated_at)
    end
  end

  it "initializes updated_at to now for a fresh session with no persisted value" do
    before = Time.now
    data = agent.to_session_data
    expect(Time.parse(data[:updated_at])).to be_within(2).of(before)
  end
end
