# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "pathname"

RSpec.describe Clacky::CLI do
  describe "rich UI compatibility" do
    it "exits before loading rich UI on Ruby versions older than 2.6" do
      cli = described_class.new
      allow(cli).to receive(:options).and_return({ ui: "rich" })
      allow(cli).to receive(:check_brand_license_cli)
      allow(cli).to receive(:say)
      stub_const("RUBY_VERSION", "2.5.8")

      expect do
        cli.send(:run_agent_with_ui2, double("agent"), Dir.pwd, double("agent_config"))
      end.to raise_error(SystemExit)

      expect(cli).to have_received(:say).with(
        "Error: Rich UI requires Ruby >= 2.6. Use --ui ui2 on Ruby 2.5.8.",
        :red
      )
    end
  end

  describe "working directory validation" do
    let(:cli) { Clacky::CLI.new }

    it "uses current directory when no path is specified" do
      result = cli.send(:validate_working_directory, nil)
      expect(result).to eq(Dir.pwd)
    end

    it "expands relative paths to absolute paths" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p("subdir")
          result = cli.send(:validate_working_directory, "subdir")
          expected = Pathname.new(File.join(dir, "subdir")).realpath.to_s
          expect(Pathname.new(result).realpath.to_s).to eq(expected)
        end
      end
    end

    it "validates that the path exists" do
      expect do
        cli.send(:validate_working_directory, "/nonexistent/path")
      end.to raise_error(SystemExit)
    end

    it "validates that the path is a directory" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "file.txt")
        File.write(file_path, "test")

        expect do
          cli.send(:validate_working_directory, file_path)
        end.to raise_error(SystemExit)
      end
    end
  end

  describe "agent runtime model guard" do
    let(:cli) { described_class.new }

    it "directs runtime-provider users to the Web UI instead of building an API client" do
      config = Clacky::AgentConfig.new(models: [
        {
          "id" => "codex-card",
          "provider_id" => "codex",
          "runtime_id" => "codex",
          Clacky::AgentConfig::RUNTIME_MODEL_MARKER => true,
          "type" => "default"
        }
      ])

      expect do
        cli.send(:ensure_cli_model_supported!, config)
      end.to raise_error(Thor::Error, /clacky server.*ChatGPT/i)
    end

    it "continues to accept ordinary API model cards" do
      config = Clacky::AgentConfig.new(models: [
        {
          "id" => "api-card",
          "model" => "gpt-test",
          "base_url" => "https://example.invalid",
          "api_key" => "secret",
          "type" => "default"
        }
      ])

      expect(cli.send(:ensure_cli_model_supported!, config)).to be_nil
    end
  end
end
