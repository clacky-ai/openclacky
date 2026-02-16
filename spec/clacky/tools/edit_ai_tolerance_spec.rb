# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::Tools::Edit do
  let(:tool) { described_class.new }

  describe "AI error tolerance" do
    context "when AI adds extra whitespace" do
      it "handles old_string with extra leading/trailing newlines" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.rb")
          File.write(file_path, "def hello\n  puts 'world'\nend")

          # AI adds extra newlines before and after
          result = tool.execute(
            path: file_path,
            old_string: "\ndef hello\n  puts 'world'\nend\n",
            new_string: "def goodbye\n  puts 'ruby'\nend"
          )

          expect(result[:error]).to be_nil
          expect(result[:replacements]).to eq(1)
          expect(File.read(file_path)).to eq("def goodbye\n  puts 'ruby'\nend")
        end
      end

      it "handles old_string with only trailing newlines" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.rb")
          File.write(file_path, "puts 'hello'")

          result = tool.execute(
            path: file_path,
            old_string: "puts 'hello'\n\n",
            new_string: "puts 'world'"
          )

          expect(result[:error]).to be_nil
          expect(result[:replacements]).to eq(1)
        end
      end
    end

    context "when AI over-escapes backslashes" do
      it 'handles over-escaped Unicode sequences (double backslash u)' do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.rb")
          # File contains actual control character (form feed)
          File.write(file_path, "when \"\u000C\" then :ctrl_l\nwhen \"\u0012\" then :ctrl_r")

          # AI over-escapes the backslash: writes \\u000C instead of \u000C
          result = tool.execute(
            path: file_path,
            old_string: "when \"\\u000C\" then :ctrl_l",
            new_string: "when \"\u000C\" then :ctrl_l  # Form feed"
          )

          expect(result[:error]).to be_nil
          expect(result[:replacements]).to eq(1)
          expect(File.read(file_path)).to include("# Form feed")
        end
      end

      it 'handles over-escaped newline sequences (double backslash n)' do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.rb")
          File.write(file_path, "str = \"hello\nworld\"")

          # AI writes \\n as literal text instead of newline character
          result = tool.execute(
            path: file_path,
            old_string: "str = \"hello\\nworld\"",
            new_string: "str = \"hello\nruby\""
          )

          expect(result[:error]).to be_nil
          expect(result[:replacements]).to eq(1)
        end
      end

      it "handles over-escaped tab sequences" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.rb")
          File.write(file_path, "data = \"col1\tcol2\"")

          result = tool.execute(
            path: file_path,
            old_string: "data = \"col1\\tcol2\"",
            new_string: "data = \"a\tb\""
          )

          expect(result[:error]).to be_nil
          expect(result[:replacements]).to eq(1)
        end
      end
    end

    context "when AI combines multiple issues" do
      it "handles both extra whitespace and over-escaped sequences" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.rb")
          File.write(file_path, "  when \"\u000C\" then :ctrl_l\n  when \"\u0012\" then :ctrl_r")

          # AI adds leading newline AND over-escapes Unicode
          result = tool.execute(
            path: file_path,
            old_string: "\n  when \"\\u000C\" then :ctrl_l\n  when \"\\u0012\" then :ctrl_r",
            new_string: "  when \"\u000C\" then :ctrl_l  # Fixed\n  when \"\u0012\" then :ctrl_r"
          )

          expect(result[:error]).to be_nil
          expect(result[:replacements]).to eq(1)
        end
      end

      it "handles tabs-vs-spaces with over-escaped content" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.rb")
          File.write(file_path, "    when \"\u000C\" then :ctrl_l")

          # AI uses tabs for indentation AND over-escapes
          result = tool.execute(
            path: file_path,
            old_string: "\twhen \"\\u000C\" then :ctrl_l",
            new_string: "    when \"\u000C\" then :ctrl_l  # Comment"
          )

          expect(result[:error]).to be_nil
          expect(result[:replacements]).to eq(1)
        end
      end
    end
  end
end
