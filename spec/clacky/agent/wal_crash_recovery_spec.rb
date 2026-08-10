# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# Regression guard for the WAL crash-recovery metadata bug:
# to_session_data MUST persist wal_seq + _wal_path so that
#   (a) SessionManager#save deletes the .wal file once the snapshot is on disk
#   (b) restore_session replays only post-save events (skip_seq_below = wal_seq)
# Without these, the WAL is never cleared and restore replays ALL events,
# duplicating every message already in the snapshot.
RSpec.describe Clacky::Agent, "#to_session_data WAL metadata" do
  let(:client) { instance_double(Clacky::Client) }
  let(:config) { Clacky::AgentConfig.new }
  let(:sid) { Clacky::SessionManager.generate_id }
  let(:sessions_dir) { Dir.mktmpdir("wal_spec") }

  before do
    stub_const("Clacky::SessionManager::SESSIONS_DIR", sessions_dir)
    allow(Clacky::TrashDirectory).to receive(:sessions_trash_dir).and_return(File.join(sessions_dir, "trash"))
  end
  after { FileUtils.rm_rf(sessions_dir) }

  def new_agent(session_id = sid)
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.pwd, ui: nil, profile: "coding",
      session_id: session_id, source: :manual
    )
  end

  def history_of(agent)
    agent.instance_variable_get(:@history)
  end

  it "includes wal_seq and _wal_path after WAL is enabled (restore path)" do
    agent = new_agent
    agent.restore_session(session_id: sid, created_at: "2026-08-10T00:00:00Z",
                          updated_at: "2026-08-10T00:00:00Z", messages: [])

    history = history_of(agent)
    history.append({ role: "assistant", content: "msg-1" })

    data = agent.to_session_data
    expect(data[:wal_seq]).to eq(history.wal_seq)
    expect(data[:wal_seq]).to eq(1)
    expect(data[:_wal_path]).to eq(history.wal_path)
    expect(data[:_wal_path]).to eq(File.join(sessions_dir, "#{sid}.wal"))
  end

  it "strips _wal_path from the on-disk session.json (never serialised)" do
    agent = new_agent
    agent.restore_session(session_id: sid, created_at: "2026-08-10T00:00:00Z",
                          updated_at: "2026-08-10T00:00:00Z", messages: [])
    history_of(agent).append({ role: "assistant", content: "msg-1" })

    sm = Clacky::SessionManager.new(sessions_dir: sessions_dir)
    path = sm.save(agent.to_session_data)
    on_disk = JSON.parse(File.read(path), symbolize_names: true)

    expect(on_disk.key?(:_wal_path)).to be(false)
    expect(on_disk.key?(:wal_seq)).to be(true)
  end

  it "deletes the .wal file after a successful save (no unbounded growth)" do
    agent = new_agent
    agent.restore_session(session_id: sid, created_at: "2026-08-10T00:00:00Z",
                          updated_at: "2026-08-10T00:00:00Z", messages: [])
    history = history_of(agent)
    history.append({ role: "assistant", content: "msg-1" })
    history.append({ role: "assistant", content: "msg-2" })

    wal_path = File.join(sessions_dir, "#{sid}.wal")
    expect(File.exist?(wal_path)).to be(true) # mutations wrote a WAL

    sm = Clacky::SessionManager.new(sessions_dir: sessions_dir)
    sm.save(agent.to_session_data)

    expect(File.exist?(wal_path)).to be(false) # save cleared it
  end

  it "does not duplicate messages across a save → mutate → crash → restore cycle" do
    sm = Clacky::SessionManager.new(sessions_dir: sessions_dir)

    # Round 1: restore (enables WAL), apply two messages, save.
    a1 = new_agent
    a1.restore_session(session_id: sid, created_at: "2026-08-10T00:00:00Z",
                       updated_at: "2026-08-10T00:00:00Z", messages: [])
    history_of(a1).append({ role: "assistant", content: "msg-1" })
    history_of(a1).append({ role: "assistant", content: "msg-2" })
    sm.save(a1.to_session_data)

    # Round 2: post-save mutation (crash happens before the next save).
    history_of(a1).append({ role: "assistant", content: "msg-3" })

    # Round 3: simulate crash — reload from disk and restore (replays the WAL).
    disk = JSON.parse(JSON.generate(sm.load(sid)), symbolize_names: true)
    a2 = new_agent
    a2.restore_session(disk)

    contents = a2.to_session_data[:messages].map { |m| (m[:content] || m["content"]).to_s }
    expect(contents).to eq(["msg-1", "msg-2", "msg-3"])
    expect(contents.group_by(&:itself).values.map(&:size).max || 0).to eq(1) # nothing duplicated
  end

  it "does NOT eagerly enable WAL for a brand-new session (avoids stray-file replay)" do
    # Deliberate design: WAL is enabled by restore_session, not by
    # initialize. Enabling it here wrote real files into the global
    # SESSIONS_DIR that restore tests (reusing a session_id without
    # stubbing the dir) then mis-replayed, doubling messages.
    agent = new_agent
    history = history_of(agent)
    expect(history.wal_path).to be_nil
    expect(history.wal_seq).to eq(0)

    # to_session_data still carries the (default) values harmlessly.
    data = agent.to_session_data
    expect(data[:wal_seq]).to eq(0)
    expect(data[:_wal_path]).to be_nil
  end

  it "discards a stray .wal when restoring a session that lacks wal_seq (legacy/fixture)" do
    # Reproduces agent_spec.rb from_session pollution: a fixed-id session
    # restored from a fixture (no wal_seq) must NOT replay a coexisting
    # stray .wal — doing so doubles every message in the snapshot.
    wal_path = File.join(sessions_dir, "#{sid}.wal")
    File.write(wal_path, [
      { seq: 1, op: "append", msg: { role: "assistant", content: "stray" } },
      { seq: 2, op: "append", msg: { role: "assistant", content: "stray2" } }
    ].map { |e| JSON.generate(e) }.join("\n") + "\n")

    fixture = {
      session_id: sid, created_at: "2026-08-10T00:00:00Z", updated_at: "2026-08-10T00:00:00Z",
      messages: [{ role: "user", content: "base" }]
      # NOTE: no :wal_seq key — legacy/fixture shape
    }

    agent = new_agent
    agent.restore_session(fixture)

    contents = agent.to_session_data[:messages].map { |m| (m[:content] || m["content"]).to_s }
    expect(contents).to eq(["base"])            # nothing appended
    expect(File.exist?(wal_path)).to be(false)  # stray WAL discarded
  end
end
