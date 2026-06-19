# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Clacky::Utils::ScriptsManager do
  describe "DEFAULT_SCRIPTS_DIR" do
    it "points to the gem scripts/ directory (not a parent workspace)" do
      dir = described_class::DEFAULT_SCRIPTS_DIR
      # Must end with /scripts, not /../scripts or similar
      expect(dir).to end_with("/scripts")
      # The gem root is openclacky/ — confirm the resolved path contains it
      expect(dir).to match(%r{open-?clacky})
      # Sanity: the directory must actually exist
      expect(Dir.exist?(dir)).to be(true), "DEFAULT_SCRIPTS_DIR does not exist: #{dir}"
    end

    it "contains the expected bundled scripts" do
      described_class::SCRIPTS.each do |script|
        path = File.join(described_class::DEFAULT_SCRIPTS_DIR, script)
        expect(File.exist?(path)).to be(true), "Bundled script missing: #{path}"
      end
    end
  end

  describe ".setup!" do
    let(:tmp_scripts_dir) { Dir.mktmpdir }

    before do
      stub_const("Clacky::Utils::ScriptsManager::SCRIPTS_DIR", tmp_scripts_dir)
      stub_const("Clacky::Utils::ScriptsManager::VERSION_FILE",
                 File.join(tmp_scripts_dir, ".version"))
    end

    after { FileUtils.rm_rf(tmp_scripts_dir) }

    it "copies all bundled scripts into SCRIPTS_DIR" do
      described_class.setup!

      described_class::SCRIPTS.each do |script|
        dest = File.join(tmp_scripts_dir, script)
        expect(File.exist?(dest)).to be(true), "Script not copied: #{script}"
      end
    end

    it "sets scripts to executable (mode 0755)" do
      described_class.setup!

      described_class::SCRIPTS.each do |script|
        dest = File.join(tmp_scripts_dir, script)
        mode = File.stat(dest).mode & 0o777
        expect(mode).to eq(0o755), "#{script} should be 0755 but got #{mode.to_s(8)}"
      end
    end

    it "writes a version stamp file after setup" do
      described_class.setup!

      version_file = File.join(tmp_scripts_dir, ".version")
      expect(File.exist?(version_file)).to be(true)
      expect(File.read(version_file).strip).to eq(Clacky::VERSION)
    end

    it "re-copies scripts when gem version changes" do
      described_class.setup!

      # Simulate an old install: corrupt the script and stamp an old version
      script = described_class::SCRIPTS.first
      dest   = File.join(tmp_scripts_dir, script)
      File.write(dest, "old content")
      File.write(File.join(tmp_scripts_dir, ".version"), "0.0.0")

      described_class.setup!

      expect(File.read(dest)).not_to eq("old content")
    end

    it "does not re-copy scripts when version is unchanged" do
      described_class.setup!

      script = described_class::SCRIPTS.first
      dest   = File.join(tmp_scripts_dir, script)
      # Replace content after setup, but stamp with current version
      File.write(dest, "custom content")
      File.write(File.join(tmp_scripts_dir, ".version"), Clacky::VERSION)

      described_class.setup!

      expect(File.read(dest)).to eq("custom content")
    end
  end

  describe ".path_for" do
    let(:tmp_scripts_dir) { Dir.mktmpdir }

    before do
      stub_const("Clacky::Utils::ScriptsManager::SCRIPTS_DIR", tmp_scripts_dir)
    end

    after { FileUtils.rm_rf(tmp_scripts_dir) }

    it "returns full path when script exists" do
      name = described_class::SCRIPTS.first
      FileUtils.touch(File.join(tmp_scripts_dir, name))
      expect(described_class.path_for(name)).to eq(File.join(tmp_scripts_dir, name))
    end

    it "returns nil when script does not exist" do
      expect(described_class.path_for("nonexistent.sh")).to be_nil
    end
  end
end
