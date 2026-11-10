# frozen_string_literal: true
require "spec_helper"
require "clacky/server/http_server"

RSpec.describe "WebSocket extension events" do
  let(:server) { Clacky::Server::HttpServer.allocate }
  let(:conn) { double("connection", send_json: nil) }
  let(:extension) { Class.new(Clacky::ApiExtension) }

  before do
    @original_registry = Clacky::ApiExtension.registry.dup
    Clacky::ApiExtension.registry.clear
    Clacky::ApiExtension.register("example", extension)
  end

  after { Clacky::ApiExtension.registry.replace(@original_registry) }

  it "dispatches namespaced input with the actual connection and replies only there" do
    other = double("other connection")
    expect(other).not_to receive(:send_json)
    expect(extension).to receive(:on_ws_event).with(conn, { "type" => "ext.example.request", "value" => 1 }) do |socket, _message|
      socket.send_json(type: "ext.example.response")
      true
    end
    expect(conn).to receive(:send_json).with(type: "ext.example.response")
    server.send(:on_ws_message, conn, JSON.generate(type: "ext.example.request", value: 1))
  end

  it "keeps native frames out of extensions and rejects unhandled namespaces" do
    expect(extension).not_to receive(:on_ws_event)
    expect(conn).to receive(:send_json).with(type: "pong")
    server.send(:on_ws_message, conn, '{"type":"ping"}')
    expect(conn).to receive(:send_json).with(hash_including(type: "error"))
    server.send(:on_ws_message, conn, '{"type":"ext.other.request"}')
  end

  it "preserves unknown-event errors for extensions without a handler" do
    expect(conn).to receive(:send_json).with(hash_including(type: "error"))
    server.send(:on_ws_message, conn, '{"type":"ext.example.unknown"}')
  end

  it "reports handler failures through the existing error path" do
    allow(extension).to receive(:on_ws_event).and_raise("failed")
    expect(conn).to receive(:send_json).with(type: "error", message: "failed")
    server.send(:on_ws_message, conn, '{"type":"ext.example.request"}')
  end

  it "cleans subscriptions before notifying extensions and isolates close failures" do
    server.instance_variable_set(:@ws_mutex, Mutex.new)
    server.instance_variable_set(:@all_ws_conns, [conn])
    expect(server).to receive(:unsubscribe).with(conn).ordered
    expect(extension).to receive(:on_ws_close).with(conn).ordered.and_raise("failed")
    other = Class.new(Clacky::ApiExtension)
    Clacky::ApiExtension.register("other", other)
    expect(other).to receive(:on_ws_close).with(conn)
    server.send(:on_ws_close, conn)
    expect(server.instance_variable_get(:@all_ws_conns)).to be_empty
  end
end
