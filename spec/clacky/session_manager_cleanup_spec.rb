# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Clacky::SessionManager, "#cleanup_by_count" do
  let(:temp_dir) { Dir.mktmpdir("clacky_sm_cleanup_spec") }
  let(:trash_dir) { File.join(temp_dir, "sessions-trash") }
  subject(:manager) { described_class.new(sessions_dir: temp_dir) }

  before do
    # soft_delete / list_trash_sessions use a global trash path; redirect it to
    # a temp dir so the test never touches the real ~/.clacky session trash.
    allow(Clacky::TrashDirectory).to receive(:sessions_trash_dir).and_return(trash_dir)
  end

  after { FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir) }

  # Write a session JSON directly so we control created_at / pinned without
  # triggering save's own cleanup pass.
  def write_session(id:, created_at:, pinned: false)
    filename = manager.send(:generate_filename, id, created_at)
    data = {
      session_id: id,
      created_at: created_at,
      updated_at: created_at,
      pinned:     pinned,
      messages:   []
    }
    File.write(File.join(temp_dir, filename), JSON.generate(data))
  end

  def active_ids
    manager.all_sessions.map { |s| s[:session_id] }
  end

  def trashed_ids
    manager.list_trash_sessions.map { |s| s[:session_id] }
  end

  it "soft-deletes the oldest non-pinned overflow (recoverable, not hard-deleted)" do
    write_session(id: "aaa", created_at: "2026-01-01T00:00:00Z") # oldest
    write_session(id: "bbb", created_at: "2026-02-01T00:00:00Z")
    write_session(id: "ccc", created_at: "2026-03-01T00:00:00Z") # newest

    evicted = manager.cleanup_by_count(keep: 2)

    expect(evicted).to eq(1)
    expect(active_ids).to contain_exactly("bbb", "ccc")
    # The evicted session went to the trash and is recoverable.
    expect(trashed_ids).to contain_exactly("aaa")
  end

  it "never soft-deletes pinned sessions and does not count them toward the cap" do
    write_session(id: "pin", pinned: true, created_at: "2026-01-01T00:00:00Z") # oldest, pinned
    write_session(id: "bbb", created_at: "2026-02-01T00:00:00Z")
    write_session(id: "ccc", created_at: "2026-03-01T00:00:00Z")
    write_session(id: "ddd", created_at: "2026-04-01T00:00:00Z")

    # keep=2 applies only to the 3 non-pinned sessions → 1 oldest non-pinned evicted.
    evicted = manager.cleanup_by_count(keep: 2)

    expect(evicted).to eq(1)
    expect(active_ids).to contain_exactly("pin", "ccc", "ddd")
    expect(trashed_ids).to contain_exactly("bbb")
  end

  it "is a no-op when the non-pinned count is within the cap" do
    write_session(id: "aaa", created_at: "2026-01-01T00:00:00Z")
    write_session(id: "bbb", created_at: "2026-02-01T00:00:00Z")

    expect(manager.cleanup_by_count(keep: 5)).to eq(0)
    expect(active_ids).to contain_exactly("aaa", "bbb")
    expect(trashed_ids).to be_empty
  end
end
