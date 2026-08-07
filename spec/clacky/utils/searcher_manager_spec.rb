# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Clacky::Utils::SearcherManager do
  before do
    @dir = Dir.mktmpdir("clacky_searcher_manager_spec")
    @installed = File.join(@dir, "searchers")
    @bundled   = File.join(@dir, "default_searchers")
    FileUtils.mkdir_p([@installed, @bundled])
    stub_const("#{described_class}::SEARCHERS_DIR", @installed)
    stub_const("#{described_class}::DEFAULT_SEARCHERS_DIR", @bundled)
  end

  after { FileUtils.rm_rf(@dir) }

  def bundled(name, body)
    File.write(File.join(@bundled, name), body)
  end

  def installed_body(name)
    File.read(File.join(@installed, name))
  end

  describe ".setup!" do
    it "copies bundled searchers on first run" do
      bundled("tavily.rb", "# VERSION: 1\nputs '[]'\n")

      described_class.setup!

      expect(installed_body("tavily.rb")).to include("VERSION: 1")
    end

    it "is idempotent" do
      bundled("tavily.rb", "# VERSION: 1\nputs '[]'\n")
      described_class.setup!
      File.write(File.join(@installed, "tavily.rb"), "# VERSION: 1\n# edited\n")

      described_class.setup!

      expect(installed_body("tavily.rb")).to include("edited")
    end

    it "upgrades and backs up when the bundled version is newer" do
      bundled("tavily.rb", "# VERSION: 1\nold\n")
      described_class.setup!
      File.write(File.join(@installed, "tavily.rb"), "# VERSION: 1\nuser edit\n")
      bundled("tavily.rb", "# VERSION: 2\nnew\n")

      described_class.setup!

      expect(installed_body("tavily.rb")).to include("new")
      expect(File.read(File.join(@installed, "tavily.rb.v1.bak"))).to include("user edit")
    end

    it "leaves the user copy alone when the bundled file has no VERSION marker" do
      bundled("custom.rb", "puts 'bundled'\n")
      described_class.setup!
      File.write(File.join(@installed, "custom.rb"), "puts 'mine'\n")
      bundled("custom.rb", "puts 'bundled v2'\n")

      described_class.setup!

      expect(installed_body("custom.rb")).to include("mine")
    end

    it "skips dotfiles and backups" do
      bundled(".DS_Store", "junk")
      bundled("old.rb.bak", "junk")

      described_class.setup!

      expect(Dir.children(@installed)).to be_empty
    end
  end

  describe ".path_for" do
    it "resolves an installed searcher" do
      File.write(File.join(@installed, "tavily.rb"), "puts '[]'")

      expect(described_class.path_for("tavily")).to eq(File.join(@installed, "tavily.rb"))
    end

    it "returns nil for a missing searcher" do
      expect(described_class.path_for("ghost")).to be_nil
    end

    it "returns nil for a blank name" do
      expect(described_class.path_for("  ")).to be_nil
    end

    it "refuses to escape the searchers directory" do
      expect(described_class.path_for("../../../etc/passwd")).to be_nil
    end

    it "ignores files with unknown extensions" do
      File.write(File.join(@installed, "notes.txt"), "hello")

      expect(described_class.path_for("notes")).to be_nil
    end
  end

  describe ".available" do
    it "lists installed searcher names sorted" do
      File.write(File.join(@installed, "tavily.rb"), "x")
      File.write(File.join(@installed, "brave.py"), "x")
      File.write(File.join(@installed, "readme.txt"), "x")

      expect(described_class.available).to eq(%w[brave tavily])
    end
  end

  describe ".interpreter_for" do
    it "maps extensions to interpreters" do
      expect(described_class.interpreter_for("a.py")).to eq("python3")
      expect(described_class.interpreter_for("a.rb")).to eq(RbConfig.ruby)
    end
  end
end
