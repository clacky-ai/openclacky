# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "pathname"

RSpec.describe Clacky::CLI do
  describe "task resource option" do
    around do |example|
      previous = ENV["CLACKY_TASK_CGROUP"]
      begin
        example.run
      ensure
        # ClimateControl preserves changes made inside its block by the code
        # under test. CLI#server sets this variable, so restore it explicitly.
        ENV["CLACKY_TASK_CGROUP"] = previous
      end
    end

    it "validates the delegated group and passes configuration through the worker environment" do
      require "clacky/server/server_master"
      allow($stderr).to receive(:isatty).and_return(true)
      allow(Clacky::Telemetry).to receive(:startup!)
      expect(Clacky::Utils::ResourceGroup).to receive(:validate!).with("/sys/fs/cgroup/tasks")
      allow(Clacky::Server::Master).to receive(:new) do
        expect(ENV["CLACKY_TASK_CGROUP"]).to eq("/sys/fs/cgroup/tasks")
        double("master", run: nil)
      end
      ClimateControl.modify("CLACKY_WORKER" => nil, "CLACKY_TASK_CGROUP" => nil) do
        described_class.start(["server", "--task-cgroup", "/sys/fs/cgroup/tasks"])
      end
    end
  end

  describe "server strict port option" do
    it "passes the parsed flag to the master and preserves it for worker restarts" do
      require "clacky/server/server_master"
      allow($stderr).to receive(:isatty).and_return(true)
      allow(Clacky::Telemetry).to receive(:startup!)
      master = double("master", run: nil)
      expect(Clacky::Server::Master).to receive(:new).with(
        host: "127.0.0.1", port: 7070, strict_port: true, extra_flags: ["--strict-port"],
      ).and_return(master)
      ClimateControl.modify("CLACKY_WORKER" => nil) do
        described_class.start(["server", "--port", "7070", "--strict-port"])
      end
    end
  end

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
end
