# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Clacky::SessionManager, "#files_for" do
  let(:temp_dir) { Dir.mktmpdir("clacky_sm_spec") }
  let(:trash_dir) { File.join(temp_dir, "sessions-trash") }
  subject(:manager) { described_class.new(sessions_dir: temp_dir) }

  before do
    allow(Clacky::TrashDirectory).to receive(:sessions_trash_dir)
      .and_return(trash_dir)
  end

  after { FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir) }

  def persist_session(session_id: "abcdef1234567890", created_at: "2025-01-02T03:04:05+00:00")
    data = { session_id: session_id, created_at: created_at, updated_at: created_at, messages: [] }
    manager.save(data)
    data
  end

  it "returns nil when the session does not exist" do
    expect(manager.files_for("nope")).to be_nil
  end

  it "returns the json path and no chunks when nothing is archived" do
    data = persist_session
    result = manager.files_for(data[:session_id])

    expect(result).not_to be_nil
    expect(result[:json_path]).to end_with(".json")
    expect(File.exist?(result[:json_path])).to be true
    expect(result[:chunks]).to eq([])
    expect(result[:session][:session_id]).to eq(data[:session_id])
  end

  it "includes all chunk-*.md files, sorted" do
    data = persist_session
    base = File.basename(manager.last_saved_path, ".json")

    # Create chunks out-of-order to confirm sort.
    [3, 1, 2].each do |n|
      File.write(File.join(temp_dir, "#{base}-chunk-#{n}.md"), "chunk #{n}")
    end

    result = manager.files_for(data[:session_id])
    expect(result[:chunks].size).to eq(3)
    expect(result[:chunks].map { |p| File.basename(p) }).to eq(
      ["#{base}-chunk-1.md", "#{base}-chunk-2.md", "#{base}-chunk-3.md"]
    )
  end

  it "matches by session id prefix (consistent with load/delete)" do
    data = persist_session(session_id: "deadbeefcafebabe")
    result = manager.files_for("deadbeef")
    expect(result).not_to be_nil
    expect(result[:session][:session_id]).to eq(data[:session_id])
  end

  it "never recreates an active file after that session was soft-deleted" do
    data = persist_session
    expect(manager.soft_delete(data[:session_id])).to be(true)

    expect(manager.save(data.merge(updated_at: "2025-01-02T03:05:05+00:00")))
      .to be_nil
    expect(manager.load(data[:session_id])).to be_nil
    expect(manager.list_trash_sessions.map { |row| row[:session_id] })
      .to include(data[:session_id])
  end

  it "rejects empty or abbreviated deletion ids without poisoning later saves" do
    data = persist_session(session_id: "abcdef1234567890")

    expect(manager.soft_delete("")).to be(false)
    expect(manager.soft_delete("abcdef12")).to be(false)
    expect(manager.load(data[:session_id])).not_to be_nil

    other = data.merge(
      session_id: "fedcba0987654321",
      updated_at: "2025-01-02T03:06:05+00:00"
    )
    expect(manager.save(other)).not_to be_nil
    expect(manager.load(other[:session_id])).not_to be_nil
  end

  it "rolls back its save tombstone when moving a session to trash fails" do
    data = persist_session
    allow(Clacky::Tools::TrashManager).to receive(:soft_delete_session)
      .and_return(false)

    expect(manager.soft_delete(data[:session_id])).to be(false)
    expect(manager.save(data.merge(updated_at: "2025-01-02T03:07:05+00:00")))
      .not_to be_nil
    expect(manager.load(data[:session_id])).not_to be_nil
  end

  it "rolls back its save tombstone when moving a session to trash raises" do
    data = persist_session
    allow(Clacky::Tools::TrashManager).to receive(:soft_delete_session)
      .and_raise(Errno::EACCES, "trash unavailable")

    expect { manager.soft_delete(data[:session_id]) }
      .to raise_error(Errno::EACCES)
    expect(manager.save(data.merge(updated_at: "2025-01-02T03:08:05+00:00")))
      .not_to be_nil
    expect(manager.load(data[:session_id])).not_to be_nil
  end
end
