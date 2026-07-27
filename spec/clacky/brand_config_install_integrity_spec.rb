# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "zip"

RSpec.describe Clacky::BrandConfig, "#install_brand_skill! integrity & cleanup" do
  let(:tmp_dir)  { Dir.mktmpdir }
  let(:slug)     { "test-skill" }
  let(:dest_dir) { File.join(tmp_dir, "brand_skills", slug) }

  before do
    stub_const("Clacky::BrandConfig::CONFIG_DIR", tmp_dir)
  end

  after { FileUtils.rm_rf(tmp_dir) }

  def build_zip(path, entries)
    FileUtils.mkdir_p(File.dirname(path))
    Zip::File.open(path, create: true) do |zip|
      entries.each do |name, content|
        zip.get_output_stream(name) { |io| io.write(content) }
      end
    end
  end

  def make_subject_with_stubbed_download(zip_builder)
    subject = described_class.new
    fake_client = instance_double(Clacky::PlatformHttpClient)
    allow(fake_client).to receive(:download_file) do |_url, dest|
      zip_builder.call(dest)
      { success: true, bytes: File.size(dest), error: nil }
    end
    allow(subject).to receive(:platform_client).and_return(fake_client)
    subject
  end

  def skill_info(slug)
    {
      "name" => slug,
      "description" => "test",
      "latest_version" => { "version" => "1.0.0", "download_url" => "https://example.com/x.zip" }
    }
  end

  it "preserves the previously installed version when the new download is corrupt" do
    # Pre-existing installed version on disk.
    FileUtils.mkdir_p(dest_dir)
    File.write(File.join(dest_dir, "SKILL.md.enc"), "old-version")

    subject = make_subject_with_stubbed_download(->(dest) { File.binwrite(dest, "") })

    result = subject.install_brand_skill!(skill_info(slug), encrypted: true)

    expect(result[:success]).to be false
    expect(result[:error]).to match(/Empty ZIP/)
    # The old version must survive a failed update.
    expect(File.read(File.join(dest_dir, "SKILL.md.enc"))).to eq("old-version")
  end

  it "does not create a dest_dir when a fresh install fails" do
    subject = make_subject_with_stubbed_download(->(dest) { File.binwrite(dest, "") })

    result = subject.install_brand_skill!(skill_info(slug), encrypted: true)

    expect(result[:success]).to be false
    expect(Dir.exist?(dest_dir)).to be false
  end

  it "succeeds for built-in skills whose ZIP does not include MANIFEST.enc.json" do
    # Platform built-in skills (added by creators via the creator center) are
    # not packaged with MANIFEST.enc.json. The installer must not block on it.
    subject = make_subject_with_stubbed_download(->(dest) {
      build_zip(dest, "SKILL.md.enc" => "fake-encrypted")
    })

    result = subject.install_brand_skill!(skill_info(slug), encrypted: true)

    expect(result[:success]).to be true
    expect(Dir.exist?(dest_dir)).to be true
  end

  it "succeeds when ZIP and MANIFEST are valid" do
    manifest = JSON.generate({ "skill_id" => "x", "skill_version_id" => "v1", "files" => {} })
    subject = make_subject_with_stubbed_download(->(dest) {
      build_zip(dest, "SKILL.md.enc" => "fake-encrypted", "MANIFEST.enc.json" => manifest)
    })

    result = subject.install_brand_skill!(skill_info(slug), encrypted: true)

    expect(result[:success]).to be true
    expect(File.exist?(File.join(dest_dir, "MANIFEST.enc.json"))).to be true
  end

  it "atomically replaces the previously installed version on a successful update" do
    # Pre-existing version with a stale file that the new package no longer ships.
    FileUtils.mkdir_p(dest_dir)
    File.write(File.join(dest_dir, "SKILL.md.enc"), "old-version")
    File.write(File.join(dest_dir, "stale.txt"), "gone")

    subject = make_subject_with_stubbed_download(->(dest) {
      build_zip(dest, "SKILL.md.enc" => "new-version")
    })

    result = subject.install_brand_skill!(skill_info(slug), encrypted: true)

    expect(result[:success]).to be true
    expect(File.read(File.join(dest_dir, "SKILL.md.enc"))).to eq("new-version")
    # Stale files from the old version must not linger after replacement.
    expect(File.exist?(File.join(dest_dir, "stale.txt"))).to be false
  end

  it "leaves no staging artifacts on failure (no temp zip or staging dir)" do
    subject = make_subject_with_stubbed_download(->(dest) { File.binwrite(dest, "") })

    subject.install_brand_skill!(skill_info(slug), encrypted: true)

    root = File.join(tmp_dir, "brand_skills")
    expect(Dir.glob(File.join(root, ".#{slug}-*.zip"))).to be_empty
    expect(Dir.glob(File.join(root, ".staging-#{slug}-*"))).to be_empty
  end
end
