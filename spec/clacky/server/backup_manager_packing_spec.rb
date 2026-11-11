# frozen_string_literal: true

require "spec_helper"
require "clacky/server/backup_manager"
require "tmpdir"
require "fileutils"
require "digest"
require "open3"

# Packing a multi-GB ~/.clacky is the slowest part of "download backup" and
# used to look frozen. build_archive now streams tar through gzip itself so it
# can report how many source bytes it has consumed.
RSpec.describe Clacky::Server::BackupManager, "packing progress" do
  let(:root)      { Dir.mktmpdir("clacky-backup-src") }
  let(:out_dir)   { Dir.mktmpdir("clacky-backup-out") }
  let(:sessions)  { File.join(root, "sessions") }
  let(:trash)     { File.join(root, "trash") }
  let(:big_size)  { 24 * 1024 * 1024 }

  before do
    stub_const("Clacky::Server::BackupManager::CLACKY_DIR", root)

    FileUtils.mkdir_p(sessions)
    FileUtils.mkdir_p(trash)
    File.binwrite(File.join(root, "big.bin"), Random.new(1).bytes(big_size))
    File.write(File.join(sessions, "s1.json"), "{}")
    File.binwrite(File.join(trash, "junk.bin"), Random.new(2).bytes(4 * 1024 * 1024))
  end

  after do
    FileUtils.rm_rf(root)
    FileUtils.rm_rf(out_dir)
  end

  it "counts only the files tar will read" do
    total = described_class.send(:source_bytes, described_class::ALWAYS_EXCLUDE)

    expect(total).to eq(big_size + 2)
  end

  it "publishes monotonic progress while packing, then clears it" do
    archive = File.join(out_dir, "backup.tar.gz")
    samples = []

    sampler = Thread.new do
      300.times do
        progress = described_class.progress
        samples << progress if progress
        sleep 0.01
      end
    end

    ok = described_class.send(:build_archive, archive, described_class::ALWAYS_EXCLUDE)
    sampler.kill

    expect(ok).to be(true)
    expect(samples).not_to be_empty
    expect(samples.map { |s| s[:done] }).to eq(samples.map { |s| s[:done] }.sort)
    expect(samples.map { |s| s[:total] }.uniq).to eq([big_size + 2])
    expect(samples.map { |s| s[:done] }.max).to be > big_size * 0.5
    expect(described_class.progress).to be_nil
  end

  it "writes an archive that still excludes regenerable directories" do
    archive = File.join(out_dir, "backup.tar.gz")

    ok = described_class.send(:build_archive, archive, described_class::ALWAYS_EXCLUDE)
    listing, status = Open3.capture2("tar", "-tzf", archive)

    expect(ok).to be(true)
    expect(status).to be_success
    expect(listing).to include("sessions/s1.json")
    expect(listing).not_to include("trash/")

    # Extracting by name is not portable: GNU tar stores members as "./big.bin"
    # and only matches that exact name, while bsdtar matches "big.bin" too.
    extract_dir = Dir.mktmpdir("clacky-backup-extract")
    begin
      expect(system("tar", "-xzf", archive, "-C", extract_dir, out: File::NULL, err: File::NULL)).to be(true)
      # The deflate retry path must not duplicate or drop bytes.
      expect(Digest::SHA256.file(File.join(extract_dir, "big.bin")).hexdigest)
        .to eq(Digest::SHA256.file(File.join(root, "big.bin")).hexdigest)
    ensure
      FileUtils.rm_rf(extract_dir)
    end
  end
end
