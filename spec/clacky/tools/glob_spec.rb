# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::Tools::Glob do
  let(:tool) { described_class.new }

  describe "#execute" do
    it "finds files matching pattern" do
      Dir.mktmpdir do |dir|
        # Create test files
        FileUtils.touch(File.join(dir, "test1.rb"))
        FileUtils.touch(File.join(dir, "test2.rb"))
        FileUtils.touch(File.join(dir, "test.txt"))

        result = tool.execute(pattern: "*.rb", base_path: dir)

        expect(result[:error]).to be_nil
        expect(result[:returned]).to eq(2)
        expect(result[:matches].all? { |m| m.end_with?(".rb") }).to be true
      end
    end

    it "finds files recursively with ** pattern" do
      Dir.mktmpdir do |dir|
        # Create nested structure
        FileUtils.mkdir_p(File.join(dir, "sub"))
        FileUtils.touch(File.join(dir, "test.rb"))
        FileUtils.touch(File.join(dir, "sub", "nested.rb"))

        result = tool.execute(pattern: "**/*.rb", base_path: dir)

        expect(result[:error]).to be_nil
        expect(result[:returned]).to eq(2)
      end
    end

    it "respects limit parameter" do
      Dir.mktmpdir do |dir|
        # Create many files
        10.times { |i| FileUtils.touch(File.join(dir, "file#{i}.txt")) }

        result = tool.execute(pattern: "*.txt", base_path: dir, limit: 5)

        expect(result[:error]).to be_nil
        expect(result[:returned]).to eq(5)
        expect(result[:total_matches]).to eq(10)
        expect(result[:truncated]).to be true
      end
    end

    it "returns empty array when no matches" do
      Dir.mktmpdir do |dir|
        result = tool.execute(pattern: "*.nonexistent", base_path: dir)

        expect(result[:error]).to be_nil
        expect(result[:matches]).to be_empty
        expect(result[:total_matches]).to eq(0)
      end
    end

    it "returns error for empty pattern" do
      result = tool.execute(pattern: "", base_path: ".")

      expect(result[:error]).to include("cannot be empty")
    end

    it "returns error for non-existent base path" do
      result = tool.execute(pattern: "*.rb", base_path: "/nonexistent/path")

      expect(result[:error]).to include("does not exist")
    end

    it "excludes .git directory and its contents from results" do
      Dir.mktmpdir do |dir|
        # Create .git directory with files (simulating a git repo)
        FileUtils.mkdir_p(File.join(dir, ".git", "refs"))
        FileUtils.touch(File.join(dir, ".git", "HEAD"))
        FileUtils.touch(File.join(dir, ".git", "config"))
        FileUtils.touch(File.join(dir, ".git", "refs", "HEAD"))
        FileUtils.touch(File.join(dir, "app.rb"))

        result = tool.execute(pattern: "**/*", base_path: dir, limit: 100)

        expect(result[:error]).to be_nil
        git_files = result[:matches].select { |f| f.include?("/.git/") }
        expect(git_files).to be_empty, "Expected no .git files but got: #{git_files.inspect}"
        expect(result[:matches].map { |f| File.basename(f) }).to include("app.rb")
      end
    end

    it "excludes .svn and .hg directories from results" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".svn"))
        FileUtils.touch(File.join(dir, ".svn", "entries"))
        FileUtils.mkdir_p(File.join(dir, ".hg"))
        FileUtils.touch(File.join(dir, ".hg", "store"))
        FileUtils.touch(File.join(dir, "app.rb"))

        result = tool.execute(pattern: "**/*", base_path: dir, limit: 100)

        expect(result[:error]).to be_nil
        vcs_files = result[:matches].select { |f| f.match?(/\/(\.svn|\.hg)\//) }
        expect(vcs_files).to be_empty
        expect(result[:matches].map { |f| File.basename(f) }).to include("app.rb")
      end
    end

    it "respects nested .gitignore in subdirectories" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "frontend", "dist"))
        FileUtils.mkdir_p(File.join(dir, "frontend", "src"))
        FileUtils.mkdir_p(File.join(dir, "backend"))

        File.write(File.join(dir, "frontend", ".gitignore"), "dist/\n")

        File.write(File.join(dir, "frontend", "dist", "bundle.js"), "compiled")
        File.write(File.join(dir, "frontend", "src", "app.js"), "source")
        File.write(File.join(dir, "backend", "server.rb"), "server")

        result = tool.execute(pattern: "**/*", base_path: dir, limit: 100)

        expect(result[:error]).to be_nil
        basenames = result[:matches].map { |f| File.basename(f) }
        expect(basenames).to include("app.js", "server.rb")
        expect(basenames).not_to include("bundle.js")
      end
    end

    it "respects root .gitignore and nested .gitignore together" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "node_modules", "pkg"))
        FileUtils.mkdir_p(File.join(dir, "packages", "ui", "build"))
        FileUtils.mkdir_p(File.join(dir, "packages", "ui", "src"))

        File.write(File.join(dir, ".gitignore"), "node_modules/\n")
        File.write(File.join(dir, "packages", "ui", ".gitignore"), "build/\n")

        File.write(File.join(dir, "node_modules", "pkg", "index.js"), "dep")
        File.write(File.join(dir, "packages", "ui", "build", "out.js"), "compiled")
        File.write(File.join(dir, "packages", "ui", "src", "app.js"), "source")

        result = tool.execute(pattern: "**/*.js", base_path: dir, limit: 100)

        expect(result[:error]).to be_nil
        filenames = result[:matches].map { |f| File.basename(f) }
        expect(filenames).to eq(["app.js"])
      end
    end

    context "auto-completion for bare patterns (no slash, no **)" do
      it "auto-expands bare filename pattern to recursive search across subdirectories" do
        Dir.mktmpdir do |dir|
          # File is inside a subdirectory, NOT in root
          FileUtils.mkdir_p(File.join(dir, "scripts"))
          FileUtils.touch(File.join(dir, "scripts", "install.sh"))

          # Pattern has no slash and no **, should auto-expand to **/*install*
          result = tool.execute(pattern: "*install*", base_path: dir)

          expect(result[:error]).to be_nil
          expect(result[:returned]).to eq(1)
          expect(result[:matches].first).to end_with("install.sh")
        end
      end

      it "auto-expands bare extension pattern to recursive search" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "deep", "nested"))
          FileUtils.touch(File.join(dir, "deep", "nested", "app.rb"))
          FileUtils.touch(File.join(dir, "deep", "lib.rb"))

          result = tool.execute(pattern: "*.rb", base_path: dir)

          expect(result[:error]).to be_nil
          expect(result[:returned]).to eq(2)
        end
      end

      it "still finds files in root dir when using bare pattern" do
        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, "install.sh"))
          FileUtils.mkdir_p(File.join(dir, "scripts"))
          FileUtils.touch(File.join(dir, "scripts", "install.sh"))

          result = tool.execute(pattern: "*install*", base_path: dir)

          expect(result[:error]).to be_nil
          expect(result[:returned]).to eq(2)
        end
      end

      it "does NOT auto-expand pattern that already contains slash" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "scripts"))
          FileUtils.touch(File.join(dir, "scripts", "install.sh"))
          # Pattern with slash should NOT auto-expand, so root-level search finds nothing
          result = tool.execute(pattern: "scripts/*.sh", base_path: dir)

          expect(result[:error]).to be_nil
          expect(result[:returned]).to eq(1)
        end
      end

      it "does NOT auto-expand pattern that already starts with **" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "scripts"))
          FileUtils.touch(File.join(dir, "scripts", "install.sh"))

          result = tool.execute(pattern: "**/*install*", base_path: dir)

          expect(result[:error]).to be_nil
          expect(result[:returned]).to eq(1)
        end
      end
    end

    it "excludes directories from results" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir(File.join(dir, "subdir"))
        FileUtils.touch(File.join(dir, "file.txt"))

        result = tool.execute(pattern: "*", base_path: dir)

        expect(result[:error]).to be_nil
        # Should only find the file, not the directory
        expect(result[:returned]).to eq(1)
        expect(result[:matches].first).to end_with("file.txt")
      end
    end
  end

  describe "working_dir resolution" do
    it "resolves base_path '.' relative to working_dir, not process cwd" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "hello.rb"))

        # base_path is "." and working_dir is dir — should search dir, not process cwd
        result = tool.execute(pattern: "*.rb", base_path: ".", working_dir: dir)

        expect(result[:error]).to be_nil
        expect(result[:matches].map { |m| File.basename(m) }).to include("hello.rb")
        # Must NOT return files from the process cwd
        expect(result[:matches].none? { |m| m.start_with?(Dir.pwd) }).to be true
      end
    end

    it "resolves relative base_path against working_dir" do
      Dir.mktmpdir do |dir|
        subdir = File.join(dir, "src")
        FileUtils.mkdir_p(subdir)
        FileUtils.touch(File.join(subdir, "app.js"))

        result = tool.execute(pattern: "*.js", base_path: "src", working_dir: dir)

        expect(result[:error]).to be_nil
        expect(result[:matches].map { |m| File.basename(m) }).to include("app.js")
      end
    end

    it "still works with absolute base_path regardless of working_dir" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "data.txt"))

        result = tool.execute(pattern: "*.txt", base_path: dir, working_dir: "/some/other/dir")

        expect(result[:error]).to be_nil
        expect(result[:matches].map { |m| File.basename(m) }).to include("data.txt")
      end
    end
  end

  describe "broad-path guard" do
    it "refuses to glob from filesystem root" do
      result = tool.execute(pattern: "*.rb", base_path: "/")
      expect(result[:error]).to include("Refusing to recursively glob")
    end

    it "refuses to glob from /root" do
      allow(Dir).to receive(:exist?).and_call_original
      allow(Dir).to receive(:exist?).with("/root").and_return(true)

      result = tool.execute(pattern: "*.rb", base_path: "/root")
      expect(result[:error]).to include("Refusing to recursively glob")
    end

    it "refuses to glob from a WSL drive mount (/mnt/c)" do
      allow(Dir).to receive(:exist?).and_call_original
      allow(Dir).to receive(:exist?).with("/mnt/c").and_return(true)

      result = tool.execute(pattern: "*.rb", base_path: "/mnt/c")
      expect(result[:error]).to include("Refusing to recursively glob")
    end

    it "still allows narrow project paths under /Users or /home" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "ok.rb"))
        result = tool.execute(pattern: "*.rb", base_path: dir)
        expect(result[:error]).to be_nil
      end
    end
  end

  describe "walk budget" do
    it "stops when max_dirs_visited is exceeded and reports truncation_reason" do
      Dir.mktmpdir do |dir|
        # Build a chain of 30 nested subdirs, each with a .rb file.
        current = dir
        30.times do |i|
          current = File.join(current, "sub#{i}")
          FileUtils.mkdir_p(current)
          FileUtils.touch(File.join(current, "f#{i}.rb"))
        end

        # Force a tiny dir budget by stubbing the constant.
        stub_const("Clacky::Utils::FileIgnoreHelper::MAX_DIRS_VISITED", 5)

        result = tool.execute(pattern: "**/*.rb", base_path: dir, limit: 100)

        expect(result[:error]).to be_nil
        expect(result[:truncated]).to be true
        expect(result[:truncation_reason]).to eq("max_dirs_visited")
      end
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("glob")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("pattern")
    end
  end
end
