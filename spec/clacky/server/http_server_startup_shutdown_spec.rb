# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "shutdown during startup" do
  let(:socket) { TCPServer.new("127.0.0.1", 0) }
  let(:scheduler) { double("scheduler", start: nil, schedules: []) }
  let(:channel_manager) { double("channels", start: nil) }
  let(:browser_manager) { double("browser", start: nil) }
  let(:server) do
    described_class.new(
      host: "127.0.0.1", port: socket.local_address.ip_port,
      agent_config: Clacky::AgentConfig.new, client_factory: -> {},
      sessions_dir: @dir, projects_file: File.join(@dir, "projects.json"), socket: socket,
    )
  end

  before do
    @dir = Dir.mktmpdir
    server.instance_variable_set(:@scheduler, scheduler)
    server.instance_variable_set(:@channel_manager, channel_manager)
    server.instance_variable_set(:@browser_manager, browser_manager)
    allow(server).to receive(:trap)
    allow(server).to receive(:create_default_session)
    allow(server).to receive(:report_extension_issues)
    allow(Clacky::ApiExtensionLoader).to receive(:load_all)
    allow(Clacky::ThreadRegistry).to receive(:spawn)
  end

  after do
    socket.close unless socket.closed?
    FileUtils.remove_entry(@dir)
  end

  it "does not start background services after draining during initialization" do
    allow(Clacky::ApiExtensionLoader).to receive(:load_all) do
      server.instance_variable_set(:@draining, true)
    end
    expect(scheduler).not_to receive(:start)
    expect(browser_manager).not_to receive(:start)
    server.start
    expect(socket).to be_closed
  end

  it "stops WEBrick if draining begins between the guard and start" do
    # Keep the master's copy to check that closing the worker FD does not shut
    # down the shared kernel listener, which the next worker needs.
    master_socket = socket.dup
    allow(WEBrick::HTTPServer).to receive(:new).and_wrap_original do |create, **opts|
      webrick = create.call(**opts)
      allow(webrick).to receive(:start).and_wrap_original do |start|
        server.instance_variable_set(:@draining, true)
        webrick.listeners.delete(socket)
        start.call
      end
      webrick
    end

    Timeout.timeout(2) { server.start }
    expect(socket).to be_closed
    client = TCPSocket.new("127.0.0.1", master_socket.local_address.ip_port)
    accepted = Timeout.timeout(2) { master_socket.accept }
    expect(accepted).to be_a(TCPSocket)
  ensure
    client&.close
    accepted&.close
    master_socket&.close
  end
end
