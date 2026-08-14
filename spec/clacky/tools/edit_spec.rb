# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::Tools::Edit do
  let(:tool) { described_class.new }

  describe "#execute" do
    it "replaces string in file" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "Hello, World!")

        result = tool.execute(
          path: file_path,
          old_string: "World",
          new_string: "Ruby"
        )

        expect(result[:error]).to be_nil
        expect(result[:replacements]).to eq(1)
        expect(File.read(file_path)).to eq("Hello, Ruby!")
      end
    end

    it "replaces all occurrences when replace_all is true" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "foo bar foo baz foo")

        result = tool.execute(
          path: file_path,
          old_string: "foo",
          new_string: "qux",
          replace_all: true
        )

        expect(result[:error]).to be_nil
        expect(result[:replacements]).to eq(3)
        expect(File.read(file_path)).to eq("qux bar qux baz qux")
      end
    end

    it "returns error when string not found" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "Hello, World!")

        result = tool.execute(
          path: file_path,
          old_string: "notfound",
          new_string: "replacement"
        )

        expect(result[:error]).to include("not found")
      end
    end

    it "returns error for file not found" do
      result = tool.execute(
        path: "/nonexistent/file.txt",
        old_string: "foo",
        new_string: "bar"
      )

      expect(result[:error]).to include("not found")
    end

    it "returns error for ambiguous replacement without replace_all" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "foo foo foo")

        result = tool.execute(
          path: file_path,
          old_string: "foo",
          new_string: "bar",
          replace_all: false
        )

        expect(result[:error]).to include("appears 3 times")
      end
    end

    it "preserves whitespace and indentation" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        original = "  def hello\n    puts 'world'\n  end"
        File.write(file_path, original)

        result = tool.execute(
          path: file_path,
          old_string: "    puts 'world'",
          new_string: "    puts 'Ruby'"
        )

        expect(result[:error]).to be_nil
        expect(File.read(file_path)).to eq("  def hello\n    puts 'Ruby'\n  end")
      end
    end

    context "smart whitespace matching" do
      it "matches content with different leading whitespace (tabs vs spaces)" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.rb")
          # File has 4 spaces
          File.write(file_path, "def test\n    puts 'hello'\nend")

          # AI provides tabs instead of spaces in old_string
          result = tool.execute(
            path: file_path,
            old_string: "def test\n\tputs 'hello'\nend",
            new_string: "def test\n    puts 'world'\nend"
          )

          expect(result[:error]).to be_nil
          expect(result[:replacements]).to eq(1)
          expect(File.read(file_path)).to eq("def test\n    puts 'world'\nend")
        end
      end

      it "matches content when indentation uses mixed spaces/tabs" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.rb")
          # File has 2 spaces for first level, 4 spaces for second level
          File.write(file_path, "class Foo\n  def bar\n    'baz'\n  end\nend")

          # AI provides tab instead of 4 spaces (but same logical indentation structure)
          result = tool.execute(
            path: file_path,
            old_string: "  def bar\n\t'baz'\n  end\n",
            new_string: "  def bar\n    'qux'\n  end\n"
          )

          expect(result[:error]).to be_nil
          expect(result[:replacements]).to eq(1)
          # Should preserve original indentation
          expect(File.read(file_path)).to eq("class Foo\n  def bar\n    'qux'\n  end\nend")
        end
      end

      it "provides helpful error when first line matches but full string doesn't" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.rb")
          File.write(file_path, "def hello\n  puts 'world'\n  puts 'ruby'\nend")

          result = tool.execute(
            path: file_path,
            old_string: "def hello\n  puts 'world'\n  puts 'python'",
            new_string: "something else"
          )

          expect(result[:error]).to include("line 1")
          expect(result[:error]).to include("whitespace differences")
          expect(result[:error]).to include("TIP")
        end
      end

      it "provides helpful error with context when string not found" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.rb")
          File.write(file_path, "def hello\n  puts 'world'\nend")

          result = tool.execute(
            path: file_path,
            old_string: "def goodbye\n  puts 'world'\nend",
            new_string: "something else"
          )

          expect(result[:error]).to include("not found")
          expect(result[:error]).to include("TIP")
          expect(result[:error]).to include("file_reader")
        end
      end
    end
  end

  describe "literal replacement (no backreference interpretation)" do
    # Regression: prior to the block-form fix, String#sub(old, new) interpreted
    # \&, \1, \`, \', \\ in new_string as sed-style backreferences, silently
    # mangling literal backslashes and these escape sequences. The edit tool's
    # contract is literal replacement, so these specs lock that down.
  
    it "preserves literal backslash-ampersand without expanding to whole match" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "br.txt")
        File.write(file_path, "hello world")
  
        result = tool.execute(path: file_path, old_string: "world", new_string: "[\\&]")
  
        expect(result[:error]).to be_nil
        expect(File.read(file_path)).to eq("hello [\\&]")
      end
    end
  
    it "preserves literal backslash-1 without expanding to capture group" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "br.txt")
        File.write(file_path, "abc")
  
        result = tool.execute(path: file_path, old_string: "b", new_string: "\\1")
  
        expect(result[:error]).to be_nil
        expect(File.read(file_path)).to eq("a\\1c")
      end
    end
  
    it "preserves a literal single backslash byte" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "br.txt")
        File.write(file_path, "[/]")
  
        result = tool.execute(path: file_path, old_string: "[/]", new_string: "[/\\]")
  
        expect(result[:error]).to be_nil
        expect(File.binread(file_path).bytes).to eq([0x5b, 0x2f, 0x5c, 0x5d])
      end
    end
  
    it "preserves literal double backslash" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "br.txt")
        File.write(file_path, "x")
  
        result = tool.execute(path: file_path, old_string: "x", new_string: "\\\\")
  
        expect(result[:error]).to be_nil
        expect(File.read(file_path)).to eq("\\\\")
      end
    end
  
    it "preserves literal backslash-ampersand across all occurrences with replace_all" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "br.txt")
        File.write(file_path, "x x x")
  
        result = tool.execute(path: file_path, old_string: "x", new_string: "\\&", replace_all: true)
  
        expect(result[:error]).to be_nil
        expect(result[:replacements]).to eq(3)
        expect(File.read(file_path)).to eq("\\& \\& \\&")
      end
    end
  
    it "preserves literal backslash-1 across all occurrences with replace_all" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "br.txt")
        File.write(file_path, "a a a")
  
        result = tool.execute(path: file_path, old_string: "a", new_string: "\\1", replace_all: true)
  
        expect(result[:error]).to be_nil
        expect(File.read(file_path)).to eq("\\1 \\1 \\1")
      end
    end
  
    it "preserves literal single backslash across all occurrences with replace_all" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "br.txt")
        File.write(file_path, "a a a")
  
        result = tool.execute(path: file_path, old_string: "a", new_string: "\\", replace_all: true)
  
        expect(result[:error]).to be_nil
        expect(File.binread(file_path)).to eq("\\ \\ \\")
      end
    end
  
    it "preserves literal double backslash across all occurrences with replace_all" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "br.txt")
        File.write(file_path, "a a")
  
        result = tool.execute(path: file_path, old_string: "a", new_string: "\\\\", replace_all: true)
  
        expect(result[:error]).to be_nil
        expect(File.read(file_path)).to eq("\\\\ \\\\")
      end
    end
  end
  
  describe "CRLF line-ending preservation" do
    it "preserves CRLF endings when editing a Windows-style file with LF old_string" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "crlf.rb")
        # File uses CRLF (Windows style)
        File.binwrite(file_path, "class Foo\r\n  def bar\r\n    'baz'\r\n  end\r\nend\r\n")

        result = tool.execute(
          path: file_path,
          old_string: "    'baz'",        # AI provides LF-style string
          new_string: "    'qux'"
        )

        expect(result[:error]).to be_nil
        written = File.binread(file_path)
        # No mixed line endings: every \n must be preceded by \r
        expect(written.scan(/(?<!\r)\n/)).to be_empty
        expect(written).to include("    'qux'\r\n")
      end
    end

    it "preserves CRLF endings on replace_all in a CRLF file" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "crlf_all.rb")
        File.binwrite(file_path, "foo\r\nfoo\r\nbar\r\n")

        result = tool.execute(
          path: file_path,
          old_string: "foo",
          new_string: "FOO",
          replace_all: true
        )

        expect(result[:error]).to be_nil
        written = File.binread(file_path)
        expect(written.scan(/(?<!\r)\n/)).to be_empty
        expect(written).to eq("FOO\r\nFOO\r\nbar\r\n")
      end
    end

    it "does not add CRLF to an LF-only file" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "lf.rb")
        File.write(file_path, "line1\nline2\nline3\n")

        result = tool.execute(
          path: file_path,
          old_string: "line2",
          new_string: "LINE2"
        )

        expect(result[:error]).to be_nil
        written = File.binread(file_path)
        expect(written).not_to include("\r")
        expect(written).to eq("line1\nLINE2\nline3\n")
      end
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("edit")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("path")
      expect(definition[:function][:parameters][:required]).to include("old_string")
      expect(definition[:function][:parameters][:required]).to include("new_string")
    end
  end
end
