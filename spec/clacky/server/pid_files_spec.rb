# frozen_string_literal: true

require "spec_helper"
require "clacky/server/pid_files"

RSpec.describe Clacky::Server::PidFiles do
  before do
    allow(Clacky::AgentConfig).to receive(:load).and_return(Clacky::AgentConfig.new)
  end

  it "uses the system temporary directory when unset or blank" do
    [nil, "", "  "].each do |value|
      with_env("CLACKY_PID_DIR" => value) do
        expect(described_class.directory).to eq(Dir.tmpdir)
      end
    end
  end

  it "expands the configured path without creating the directory" do
    allow(Clacky::AgentConfig).to receive(:load).and_return(
      Clacky::AgentConfig.new(pid_dir: "~/.clacky/run")
    )
    with_env("CLACKY_PID_DIR" => nil) do
      expect(FileUtils).not_to receive(:mkdir_p)
      expect(described_class.directory).to eq(File.expand_path("~/.clacky/run"))
    end
  end

  it "lets the environment override the saved setting" do
    allow(Clacky::AgentConfig).to receive(:load).and_return(
      Clacky::AgentConfig.new(pid_dir: "/saved/run")
    )
    with_env("CLACKY_PID_DIR" => "~/custom/run") do
      expect(described_class.directory).to eq(File.expand_path("~/custom/run"))
    end
  end

  it "ignores a blank environment override and falls back from a blank setting" do
    with_env("CLACKY_PID_DIR" => " ") do
      allow(Clacky::AgentConfig).to receive(:load).and_return(Clacky::AgentConfig.new(pid_dir: "~/run"))
      expect(described_class.directory).to eq(File.expand_path("~/run"))
      allow(Clacky::AgentConfig).to receive(:load).and_return(Clacky::AgentConfig.new(pid_dir: " "))
      expect(described_class.directory).to eq(Dir.tmpdir)
    end
  end
end
