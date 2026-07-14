# frozen_string_literal: true

require "spec_helper"
require "zip"

RSpec.describe Clacky::ExtensionPackager do
  let(:local)     { Dir.mktmpdir }
  let(:installed) { Dir.mktmpdir }
  let(:out)       { Dir.mktmpdir }

  after do
    [local, installed, out].each { |d| FileUtils.remove_entry(d) if Dir.exist?(d) }
    Clacky::ExtensionLoader.invalidate_cache!
  end

  def scaffold(id)
    Clacky::ExtensionScaffold.new_container(id, dir: local)
  end

  describe ".pack" do
    it "packs a local container into a zip named <id>.zip" do
      scaffold("demo")
      res = described_class.pack("demo", source_dir: local, out_dir: out)

      expect(res.ext_id).to eq("demo")
      expect(res.path).to eq(File.join(out, "demo.zip"))
      expect(File).to exist(res.path)
    end

    it "produces an archive with a single top-level container dir holding ext.yml" do
      scaffold("demo")
      res = described_class.pack("demo", source_dir: local, out_dir: out)

      names = []
      Zip::File.open(res.path) { |z| z.each { |e| names << e.name } }
      expect(names).to include("demo/ext.yml")
      expect(names).to include("demo/panels/hello/view.js")
      tops = names.map { |n| n.split("/").first }.uniq
      expect(tops).to eq(["demo"])
    end

    it "raises when the container does not exist" do
      expect { described_class.pack("missing", source_dir: local, out_dir: out) }
        .to raise_error(described_class::Error, /no container found/)
    end

    it "refuses to pack a container carrying an encrypted skill" do
      dir = scaffold("enc")
      FileUtils.mkdir_p(File.join(dir, "skills", "secret"))
      File.write(File.join(dir, "skills", "secret", "SKILL.md.enc"), "cipher")

      expect { described_class.pack("enc", source_dir: local, out_dir: out) }
        .to raise_error(described_class::Error, /encrypted skill/)
    end

    it "blocks packing when verify reports errors" do
      dir = scaffold("broken")
      File.delete(File.join(dir, "panels/hello/view.js"))

      expect { described_class.pack("broken", source_dir: local, out_dir: out) }
        .to raise_error(described_class::Error, /verify found errors/)
    end

    it "excludes platform metadata files and dirs from the archive" do
      dir = scaffold("demo")
      FileUtils.touch(File.join(dir, ".DS_Store"))
      FileUtils.touch(File.join(dir, "panels", ".DS_Store"))
      FileUtils.touch(File.join(dir, "panels", "hello", "Thumbs.db"))
      FileUtils.touch(File.join(dir, "desktop.ini"))
      FileUtils.mkdir_p(File.join(dir, "__MACOSX", "panels"))
      FileUtils.touch(File.join(dir, "__MACOSX", "panels", "junk"))

      res = described_class.pack("demo", source_dir: local, out_dir: out)

      names = []
      Zip::File.open(res.path) { |z| z.each { |e| names << e.name } }
      expect(names).to include("demo/ext.yml")
      expect(names).to include("demo/panels/hello/view.js")
      expect(names).not_to(include(a_string_matching(%r{(\.DS_Store|Thumbs\.db|desktop\.ini|__MACOSX)})))
    end
  end

  describe ".install" do
    def packed(id)
      scaffold(id)
      described_class.pack(id, source_dir: local, out_dir: out).path
    end

    it "installs a packed zip into the installed layer and resolves its units" do
      zip = packed("demo")
      res = described_class.install(zip, installed_dir: installed)

      expect(res.ext_id).to eq("demo")
      expect(File).to exist(File.join(installed, "demo", "ext.yml"))
      expect(res.units.map(&:kind)).to contain_exactly(:panel, :api)
    end

    it "refuses to overwrite an existing extension without force" do
      zip = packed("demo")
      described_class.install(zip, installed_dir: installed)

      expect { described_class.install(zip, installed_dir: installed) }
        .to raise_error(described_class::Error, /already installed/)
    end

    it "overwrites with force: true" do
      zip = packed("demo")
      described_class.install(zip, installed_dir: installed)
      expect { described_class.install(zip, installed_dir: installed, force: true) }
        .not_to raise_error
    end

    it "raises when the local zip is missing" do
      expect { described_class.install("/no/such/file.zip", installed_dir: installed) }
        .to raise_error(described_class::Error, /zip not found/)
    end

    it "rejects an archive with no container manifest" do
      bad = File.join(out, "bad.zip")
      Zip::File.open(bad, create: true) { |z| z.get_output_stream("readme.txt") { |f| f.write("hi") } }

      expect { described_class.install(bad, installed_dir: installed) }
        .to raise_error(described_class::Error, /single container/)
    end

    it "rejects a zip-slip archive that escapes the extract root" do
      evil = File.join(out, "evil.zip")
      Zip::File.open(evil, create: true) do |z|
        z.get_output_stream("../escape.txt") { |f| f.write("pwned") }
      end

      expect { described_class.install(evil, installed_dir: installed) }
        .to raise_error(described_class::Error, /unsafe path/)
    end
  end
end
