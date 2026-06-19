# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "Snapshot reclamation" do
  let(:temp_dir)       { Dir.mktmpdir("clacky_snap_spec") }
  let(:sessions_dir)   { File.join(temp_dir, "sessions") }
  let(:trash_dir)      { File.join(temp_dir, "sessions-trash") }
  let(:snapshots_root) { File.join(temp_dir, "snapshots") }

  before do
    FileUtils.mkdir_p([sessions_dir, snapshots_root])
    allow(Clacky::TrashDirectory).to receive(:sessions_trash_dir).and_return(trash_dir)
  end

  after { FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir) }

  def write_session(manager, id:, created_at: "2026-01-01T00:00:00Z")
    filename = manager.send(:generate_filename, id, created_at)
    File.write(File.join(sessions_dir, filename), JSON.generate(
      session_id: id, created_at: created_at, updated_at: created_at, messages: []
    ))
  end

  def write_snapshot(session_id)
    dir = File.join(snapshots_root, session_id, "task-1")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "file.txt"), "x")
  end

  describe ".cleanup_orphan_snapshots" do
    subject(:manager) { Clacky::SessionManager.new(sessions_dir: sessions_dir) }

    it "removes snapshots whose session no longer exists" do
      write_session(manager, id: "aaaaaaaa11111111")
      write_snapshot("aaaaaaaa11111111") # has a live session
      write_snapshot("bbbbbbbb22222222") # orphan
      write_snapshot("cccccccc33333333") # orphan

      removed = Clacky::SessionManager.cleanup_orphan_snapshots(
        sessions_dir: sessions_dir, snapshots_root: snapshots_root
      )

      expect(removed).to eq(2)
      expect(Dir.exist?(File.join(snapshots_root, "aaaaaaaa11111111"))).to be true
      expect(Dir.exist?(File.join(snapshots_root, "bbbbbbbb22222222"))).to be false
      expect(Dir.exist?(File.join(snapshots_root, "cccccccc33333333"))).to be false
    end

    it "keeps snapshots whose session is in the trash" do
      FileUtils.mkdir_p(trash_dir)
      File.write(File.join(trash_dir, "2026-01-01-00-00-00-dddddddd.json"), JSON.generate(
        session_id: "dddddddd44444444", created_at: "2026-01-01T00:00:00Z"
      ))
      write_snapshot("dddddddd44444444")

      removed = Clacky::SessionManager.cleanup_orphan_snapshots(
        sessions_dir: sessions_dir, snapshots_root: snapshots_root
      )

      expect(removed).to eq(0)
      expect(Dir.exist?(File.join(snapshots_root, "dddddddd44444444"))).to be true
    end

    it "returns 0 when the snapshots root does not exist" do
      FileUtils.rm_rf(snapshots_root)
      expect(
        Clacky::SessionManager.cleanup_orphan_snapshots(
          sessions_dir: sessions_dir, snapshots_root: snapshots_root
        )
      ).to eq(0)
    end
  end

  describe "TrashManager._delete_snapshots" do
    it "removes the session's snapshot directory" do
      allow(Dir).to receive(:home).and_return(temp_dir)
      dir = File.join(temp_dir, ".clacky", "snapshots", "eeeeeeee55555555")
      FileUtils.mkdir_p(dir)

      Clacky::Tools::TrashManager.send(:_delete_snapshots, "eeeeeeee55555555")

      expect(Dir.exist?(dir)).to be false
    end

    it "is a no-op for a blank session_id" do
      expect {
        Clacky::Tools::TrashManager.send(:_delete_snapshots, "")
      }.not_to raise_error
    end
  end
end
