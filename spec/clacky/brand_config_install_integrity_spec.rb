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

  it "removes dest_dir when downloaded ZIP is empty" do
    subject = make_subject_with_stubbed_download(->(dest) { File.binwrite(dest, "") })

    result = subject.install_brand_skill!(skill_info(slug), encrypted: true)

    expect(result[:success]).to be false
    expect(result[:error]).to match(/Empty ZIP/)
    expect(Dir.exist?(dest_dir)).to be false
  end

  it "removes dest_dir when MANIFEST.enc.json is missing for encrypted skills" do
    subject = make_subject_with_stubbed_download(->(dest) {
      build_zip(dest, "SKILL.md.enc" => "fake-encrypted")
    })

    result = subject.install_brand_skill!(skill_info(slug), encrypted: true)

    expect(result[:success]).to be false
    expect(result[:error]).to match(/MANIFEST.enc.json missing/)
    expect(Dir.exist?(dest_dir)).to be false
  end

  it "removes dest_dir when MANIFEST.enc.json contains malformed JSON" do
    subject = make_subject_with_stubbed_download(->(dest) {
      build_zip(dest,
                "SKILL.md.enc"      => "fake-encrypted",
                "MANIFEST.enc.json" => "{not-valid-json")
    })

    result = subject.install_brand_skill!(skill_info(slug), encrypted: true)

    expect(result[:success]).to be false
    expect(result[:error]).to match(/unexpected token|JSON/)
    expect(Dir.exist?(dest_dir)).to be false
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

  it "leaves the ZIP file removed on failure (no .zip leftover)" do
    subject = make_subject_with_stubbed_download(->(dest) { File.binwrite(dest, "") })

    subject.install_brand_skill!(skill_info(slug), encrypted: true)

    expect(File.exist?(File.join(tmp_dir, "brand_skills", "#{slug}.zip"))).to be false
  end
end
