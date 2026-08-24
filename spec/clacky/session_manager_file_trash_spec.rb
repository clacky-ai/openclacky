# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "time"
require "clacky/session_manager"
require "clacky/utils/trash_directory"
require "clacky/tools/trash_manager"

RSpec.describe "file-trash rolling cleanup" do
  let!(:trash_root) { Dir.mktmpdir("clacky_file_trash_spec") }
  before { stub_const("Clacky::TrashDirectory::GLOBAL_TRASH_ROOT", trash_root) }
  after  { FileUtils.rm_rf(trash_root) }

  let(:project_a) { Dir.mktmpdir("proj_a") }
  let(:project_b) { Dir.mktmpdir("proj_b") }
  after do
    FileUtils.rm_rf(project_a)
    FileUtils.rm_rf(project_b)
  end

  def seed_trash_file(project_root:, basename:, content: "bye", deleted_at: Time.now.utc.iso8601)
    td = Clacky::TrashDirectory.new(project_root)
    ts = Time.now.strftime("%Y%m%d_%H%M%S_%L%N")
    dest = File.join(td.trash_dir, "#{basename}_deleted_#{ts}")
    File.write(dest, content)
    meta = {
      "original_path" => File.join(project_root, basename),
      "deleted_at"    => deleted_at,
      "file_size"     => content.bytesize,
      "file_type"     => File.extname(basename),
      "file_mode"     => "644"
    }
    File.write("#{dest}.metadata.json", JSON.generate(meta))
    dest
  end

  def surviving_originals(project_root)
    trash_dir = Clacky::TrashDirectory.new(project_root).trash_dir
    Dir.glob(File.join(trash_dir, "*.metadata.json")).map do |m|
      JSON.parse(File.read(m))["original_path"]
    end
  end

  describe "Clacky::Tools::TrashManager.cleanup_files_trash" do
    it "permanently deletes entries older than the window across all projects" do
      old_stamp = (Time.now - 9 * 86400).utc.iso8601
      old_a = seed_trash_file(project_root: project_a, basename: "old_a.txt", deleted_at: old_stamp)
      old_b = seed_trash_file(project_root: project_b, basename: "old_b.txt", deleted_at: old_stamp)
      seed_trash_file(project_root: project_a, basename: "fresh.txt")

      deleted = Clacky::Tools::TrashManager.cleanup_files_trash(days: 8)

      expect(deleted).to eq(2)
      expect(File.exist?(old_a)).to be(false)
      expect(File.exist?("#{old_a}.metadata.json")).to be(false)
      expect(File.exist?(old_b)).to be(false)
      expect(surviving_originals(project_a)).to eq([File.join(project_a, "fresh.txt")])
      expect(surviving_originals(project_b)).to be_empty
    end

    it "keeps entries inside the window" do
      seed_trash_file(project_root: project_a, basename: "edge.txt",
                      deleted_at: (Time.now - 7 * 86400).utc.iso8601)

      expect(Clacky::Tools::TrashManager.cleanup_files_trash(days: 8)).to eq(0)
      expect(surviving_originals(project_a)).to eq([File.join(project_a, "edge.txt")])
    end

    it "returns 0 when no trash root exists" do
      missing = File.join(Dir.mktmpdir("no_trash"), "file-trash")
      stub_const("Clacky::TrashDirectory::GLOBAL_TRASH_ROOT", File.dirname(missing))

      expect(Clacky::Tools::TrashManager.cleanup_files_trash(days: 8)).to eq(0)
    end
  end

  describe "SessionManager#save triggers cleanup" do
    let(:sessions_dir) { Dir.mktmpdir("clacky_file_trash_sessions") }
    after { FileUtils.rm_rf(sessions_dir) }

    it "purges file-trash entries older than 8 days on save" do
      old_stamp = (Time.now - 9 * 86400).utc.iso8601
      old_file = seed_trash_file(project_root: project_a, basename: "stale.log", deleted_at: old_stamp)
      seed_trash_file(project_root: project_a, basename: "recent.log")

      sm = Clacky::SessionManager.new(sessions_dir: sessions_dir)
      sm.save(
        session_id: "aabbccdd11223344",
        created_at: Time.now.utc.iso8601,
        updated_at: Time.now.utc.iso8601,
        name: "cleanup trigger"
      )

      # save schedules the trash sweep on a background thread; wait for it.
      deadline = Time.now + 5
      sleep(0.02) until !File.exist?(old_file) || Time.now > deadline

      expect(File.exist?(old_file)).to be(false)
      expect(surviving_originals(project_a)).to eq([File.join(project_a, "recent.log")])
    end
  end
end
