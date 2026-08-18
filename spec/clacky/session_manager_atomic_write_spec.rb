# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Clacky::SessionManager, "#save (atomic write)" do
  let(:temp_dir) { Dir.mktmpdir("clacky_sm_atomic_spec") }
  let(:trash_dir) { File.join(temp_dir, "sessions-trash") }
  subject(:manager) { described_class.new(sessions_dir: temp_dir) }

  before do
    allow(Clacky::TrashDirectory).to receive(:sessions_trash_dir).and_return(trash_dir)
  end

  after { FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir) }

  def session_data(id: "test-1")
    {
      session_id: id,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      messages: [{ role: "user", content: "hello" }]
    }
  end

  it "writes a valid JSON file (no truncation)" do
    path = manager.save(session_data)
    parsed = JSON.parse(File.read(path), symbolize_names: true)
    expect(parsed[:session_id]).to eq("test-1")
    expect(parsed[:messages].first[:content]).to eq("hello")
  end

  it "does not leave a .tmp file behind" do
    path = manager.save(session_data)
    expect(File.exist?("#{path}.tmp")).to be(false)
  end

  it "produces a file with 0600 permissions" do
    path = manager.save(session_data)
    stat = File.stat(path)
    expect(stat.mode & 0o777).to eq(0o600)
  end

  it "overwrites an existing file atomically (old content fully replaced)" do
    manager.save(session_data(id: "test-1"))
    path = manager.save(session_data(id: "test-1")) # second save

    # File should exist and be valid — no corruption from the rename-overwrite.
    parsed = JSON.parse(File.read(path), symbolize_names: true)
    expect(parsed[:session_id]).to eq("test-1")
  end
end

RSpec.describe Clacky::SessionManager, "#write_chunk (atomic write)" do
  let(:temp_dir) { Dir.mktmpdir("clacky_sm_chunk_atomic_spec") }
  let(:trash_dir) { File.join(temp_dir, "sessions-trash") }
  subject(:manager) { described_class.new(sessions_dir: temp_dir) }

  before do
    allow(Clacky::TrashDirectory).to receive(:sessions_trash_dir).and_return(trash_dir)
  end

  after { FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir) }

  it "writes valid chunk content" do
    path = manager.write_chunk("sess-1", "2026-01-01T00:00:00Z", 0, "# Chunk 0\nhello")
    expect(File.read(path)).to eq("# Chunk 0\nhello")
  end

  it "does not leave a .tmp file behind" do
    path = manager.write_chunk("sess-1", "2026-01-01T00:00:00Z", 0, "data")
    expect(File.exist?("#{path}.tmp")).to be(false)
  end
end
