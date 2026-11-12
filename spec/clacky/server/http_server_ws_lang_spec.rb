# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe "HttpServer WebSocket language" do
  around do |example|
    original_thread = Thread.current[:lang]
    example.run
  ensure
    Thread.current[:lang] = original_thread
  end

  let(:server) do
    Clacky::Server::HttpServer.allocate.tap do |instance|
      instance.instance_variable_set(:@ws_mutex, Mutex.new)
      instance.instance_variable_set(:@ws_clients, {})
    end
  end
  let(:conn) do
    Clacky::Server::HttpServer::WebSocketConnection.allocate.tap do |connection|
      allow(connection).to receive(:send_json).and_return(true)
    end
  end

  it "applies a supported frame language to the connection thread" do
    server.on_ws_message(conn, { type: "unknown", lang: "zh" }.to_json)

    expect(Thread.current[:lang]).to eq("zh")
  end

  it "ignores unsupported languages" do
    Thread.current[:lang] = "en"

    server.on_ws_message(conn, { type: "unknown", lang: "fr" }.to_json)

    expect(Thread.current[:lang]).to eq("en")
  end

  it "keeps the connection language when a later frame omits it" do
    server.on_ws_message(conn, { type: "unknown", lang: "zh" }.to_json)
    server.on_ws_message(conn, { type: "unknown" }.to_json)

    expect(Thread.current[:lang]).to eq("zh")
  end
end
