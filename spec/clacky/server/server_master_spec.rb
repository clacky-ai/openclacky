# frozen_string_literal: true

require "spec_helper"
require "clacky/server/server_master"

RSpec.describe Clacky::Server::Master do
  subject(:master) { described_class.new(host: "127.0.0.1", port: 7070) }

  let(:socket) { double("socket", fileno: 12) }

  before do
    allow(socket).to receive(:close_on_exec=)
    master.instance_variable_set(:@socket, socket)
    allow(master).to receive(:spawn).and_return(12_345)
  end

  def capture_spawn_environment
    captured = nil
    allow(master).to receive(:spawn) do |env, *_args|
      captured = env
      12_345
    end
    master.spawn_worker
    captured
  end

  it "inherits CLACKY_LICENSE_SERVER when no source has been saved" do
    allow(Clacky::AgentConfig).to receive(:load).and_return(
      Clacky::AgentConfig.new(clacky_license_server: nil)
    )

    env = capture_spawn_environment

    expect(env).not_to have_key("CLACKY_LICENSE_SERVER")
  end

  it "injects a saved private source into the Worker" do
    allow(Clacky::AgentConfig).to receive(:load).and_return(
      Clacky::AgentConfig.new(clacky_license_server: "https://enterprise.example.com")
    )

    env = capture_spawn_environment

    expect(env["CLACKY_LICENSE_SERVER"]).to eq("https://enterprise.example.com")
  end

  it "removes an inherited override when the official source is saved" do
    allow(Clacky::AgentConfig).to receive(:load).and_return(
      Clacky::AgentConfig.new(clacky_license_server: Clacky::PlatformHttpClient::PRIMARY_HOST)
    )

    env = capture_spawn_environment

    expect(env).to include("CLACKY_LICENSE_SERVER" => nil)
  end

  it "does not fall back from the requested port in strict mode" do
    master = described_class.new(host: "127.0.0.1", port: 7070, strict_port: true)
    allow(master).to receive(:kill_existing_master)
    allow(master).to receive(:remove_pid_file)
    expect(master).to receive(:bind_with_fallback).with("127.0.0.1", 7070, max_port: 7070).and_return(nil)
    expect { master.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end

  it "keeps the default fallback range without strict mode" do
    allow(master).to receive(:kill_existing_master)
    allow(master).to receive(:remove_pid_file)
    expect(master).to receive(:bind_with_fallback).with("127.0.0.1", 7070, max_port: 7075).and_return(nil)
    expect { master.run }.to raise_error(SystemExit)
  end

  it "allows the old master its worker cleanup budget before escalating" do
    Dir.mktmpdir do |dir|
      allow(Dir).to receive(:tmpdir).and_return(dir)
      File.write(File.join(dir, "clacky-master-7070.pid"), "12345")
      allow(Process).to receive(:kill).with("TERM", 12_345)
      expect(Process).not_to receive(:kill).with("KILL", 12_345)
      allow(master).to receive(:process_dead?).with(12_345).and_return(false, false, true, true)
      allow(Time).to receive(:now).and_return(Time.at(0), Time.at(6), Time.at(11))
      allow(master).to receive(:sleep)
      master.kill_existing_master
    end
  end

  it "does not delete a replacement master's PID file" do
    Dir.mktmpdir do |dir|
      allow(Dir).to receive(:tmpdir).and_return(dir)
      File.write(master.pid_file_path, "12345")
      master.remove_pid_file
      expect(File.read(master.pid_file_path)).to eq("12345")
    end
  end

  it "cleans the worker group even when the worker exited gracefully" do
    master.instance_variable_set(:@worker_pid, 12_345)
    expect(Process).to receive(:kill).with("TERM", -12_345).ordered
    allow(Process).to receive(:waitpid2).with(12_345, Process::WNOHANG).and_return([12_345, nil])
    expect(Process).to receive(:kill).with("KILL", -12_345).ordered
    allow(socket).to receive(:close)
    expect { master.shutdown }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
  end
end
