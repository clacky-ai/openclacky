# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::Tools::Write do
  let(:tool) { described_class.new }

  describe "#execute" do
    it "writes content to a new file" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        content = "Hello, World!"

        result = tool.execute(path: file_path, content: content)

        expect(result[:error]).to be_nil
        expect(result[:bytes_written]).to eq(content.bytesize)
        expect(File.read(file_path)).to eq(content)
      end
    end

    it "overwrites existing file" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "Old content")

        new_content = "New content"
        result = tool.execute(path: file_path, content: new_content)

        expect(result[:error]).to be_nil
        expect(File.read(file_path)).to eq(new_content)
      end
    end

    it "creates parent directories if they don't exist" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "sub", "dir", "test.txt")
        content = "Test"

        result = tool.execute(path: file_path, content: content)

        expect(result[:error]).to be_nil
        expect(File.read(file_path)).to eq(content)
      end
    end

    it "returns error for empty path" do
      result = tool.execute(path: "", content: "test")

      expect(result[:error]).to include("cannot be empty")
    end

    it "handles nil path" do
      result = tool.execute(path: nil, content: "test")

      expect(result[:error]).to include("cannot be empty")
    end

    context "with mode: append" do
      it "appends to existing file" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.txt")
          File.write(file_path, "line1\n")

          result = tool.execute(path: file_path, content: "line2\n", mode: "append")

          expect(result[:error]).to be_nil
          expect(result[:bytes_written]).to eq(6)
          expect(File.read(file_path)).to eq("line1\nline2\n")
        end
      end

      it "creates file if it does not exist" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "new.txt")

          result = tool.execute(path: file_path, content: "hello\n", mode: "append")

          expect(result[:error]).to be_nil
          expect(File.read(file_path)).to eq("hello\n")
        end
      end

      it "appends multiple times" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "log.txt")

          tool.execute(path: file_path, content: "a\n", mode: "append")
          tool.execute(path: file_path, content: "b\n", mode: "append")
          result = tool.execute(path: file_path, content: "c\n", mode: "append")

          expect(result[:error]).to be_nil
          expect(File.read(file_path)).to eq("a\nb\nc\n")
        end
      end
    end

    context "with mode: overwrite" do
      it "replaces existing content" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.txt")
          File.write(file_path, "old")

          result = tool.execute(path: file_path, content: "new", mode: "overwrite")

          expect(result[:error]).to be_nil
          expect(File.read(file_path)).to eq("new")
        end
      end
    end

    context "with default mode" do
      it "defaults to overwrite" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "test.txt")
          File.write(file_path, "old")

          result = tool.execute(path: file_path, content: "new")

          expect(result[:error]).to be_nil
          expect(File.read(file_path)).to eq("new")
        end
      end
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("write")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("path")
      expect(definition[:function][:parameters][:required]).to include("content")
    end

    it "includes mode parameter" do
      definition = tool.to_function_definition

      props = definition[:function][:parameters][:properties]
      expect(props[:mode][:enum]).to eq(%w[overwrite append])
      expect(props[:mode][:default]).to eq("overwrite")
    end
  end
end
