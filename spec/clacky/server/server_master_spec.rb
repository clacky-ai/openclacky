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
end
