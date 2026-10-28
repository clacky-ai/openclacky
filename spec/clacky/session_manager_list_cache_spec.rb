# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Clacky::SessionManager, "session list reuse" do
  let(:temp_dir) { Dir.mktmpdir("clacky_sm_list_spec") }
  subject(:manager) { described_class.new(sessions_dir: temp_dir) }

  after { FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir) }

  let(:clock) { { now: 1000.0 } }
  before { allow(manager).to receive(:monotonic_now) { clock[:now] } }

  def session_path(id, created_at)
    File.join(temp_dir, manager.send(:generate_filename, id, created_at))
  end

  def write_session(id:, created_at: "2026-09-01T10:00:00+08:00", updated_at: nil, **extra)
    File.write(session_path(id, created_at), JSON.generate({
      session_id: id,
      name:       id,
      created_at: created_at,
      updated_at: updated_at || created_at,
      messages:   []
    }.merge(extra)))
  end

  def count_parses(delay: 0)
    count = 0
    allow(manager).to receive(:load_session_file).and_wrap_original do |original, path|
      count += 1
      sleep(delay) if delay.positive?
      original.call(path)
    end
    -> { count }
  end

  it "parses the session files once within the reuse window" do
    write_session(id: "aaaa0001")
    parse_count = count_parses

    manager.all_sessions
    manager.all_sessions
    manager.all_sessions(limit: 1)

    expect(parse_count.call).to eq(1)
  end

  it "parses once when several callers arrive together" do
    write_session(id: "aaaa0001")
    write_session(id: "aaaa0002")
    parse_count = count_parses(delay: 0.05)

    threads = 4.times.map { Thread.new { manager.all_sessions } }
    threads.each(&:join)

    # Two files, one scan: four callers would mean eight parses.
    expect(parse_count.call).to eq(2)
  end

  it "scans again once the window has passed" do
    manager.all_sessions
    write_session(id: "cccc0003", created_at: "2026-09-03T10:00:00+08:00")

    clock[:now] += described_class::LIST_REUSE_WINDOW + 1

    expect(manager.all_sessions.map { |s| s[:session_id] }).to include("cccc0003")
  end

  it "rescans immediately after a session is saved" do
    manager.all_sessions
    manager.save(session_id: "bbbb0002", created_at: "2026-09-02T10:00:00+08:00", name: "fresh")

    expect(manager.all_sessions(limit: 1).first[:session_id]).to eq("bbbb0002")
  end

  it "skips an unreadable file instead of failing the listing" do
    write_session(id: "aaaa0001")
    File.write(File.join(temp_dir, "2026-09-11-10-00-00-66660012.json"), "{ truncated")

    expect(manager.all_sessions.map { |s| s[:session_id] }).to eq(["aaaa0001"])
  end

  it "returns a copy so callers cannot reorder the shared list" do
    write_session(id: "aaaa0001")
    write_session(id: "bbbb0002", created_at: "2026-09-02T10:00:00+08:00")

    manager.all_sessions.clear

    expect(manager.all_sessions.size).to eq(2)
  end
end
