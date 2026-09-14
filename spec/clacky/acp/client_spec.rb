# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Acp::Client do
  class FakeAcpTransport
    attr_reader :sent

    def initialize
      @sent = []
      @alive = false
      @on_message = nil
      @on_send = nil
    end

    def on_message(&block)
      @on_message = block
    end

    def on_send(&block)
      @on_send = block
    end

    def start
      @alive = true
      self
    end

    def stop
      @alive = false
    end

    def alive?
      @alive
    end

    def send_message(message)
      @sent << message
      @on_send.call(message) if @on_send
    end

    def emit(message)
      @on_message.call(message)
    end

    def stderr_tail(bytes: 4096)
      "diagnostic"[-bytes, bytes]
    end
  end

  let(:transport) { FakeAcpTransport.new }

  def initialized_client
    transport.on_send do |message|
      next unless message[:method] == "initialize" || message["method"] == "initialize"

      id = message[:id] || message["id"]
      transport.emit(
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => {
          "protocolVersion" => 1,
          "agentCapabilities" => {
            "loadSession" => true,
            "promptCapabilities" => { "image" => true }
          },
          "authMethods" => [{ "id" => "chat-gpt", "name" => "ChatGPT" }],
          "agentInfo" => { "name" => "codex-acp", "version" => "1.11.0" }
        }
      )
    end

    described_class.new(transport: transport).start(
      client_info: { "name" => "openclacky", "version" => "test" },
      capabilities: { "_meta" => { "authStatus" => true } }
    )
  end

  it "initializes ACP version 1 and exposes the negotiated result" do
    client = initialized_client

    initialize_message = transport.sent.first
    expect(initialize_message).to eq(
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: 1,
        clientCapabilities: { "_meta" => { "authStatus" => true } },
        clientInfo: { "name" => "openclacky", "version" => "test" }
      }
    )
    expect(client.initialized?).to be(true)
    expect(client.alive?).to be(true)
    expect(client.agent_info).to eq("name" => "codex-acp", "version" => "1.11.0")
    expect(client.agent_capabilities.dig("promptCapabilities", "image")).to be(true)
    expect(client.auth_methods.first["id"]).to eq("chat-gpt")
  ensure
    client&.stop
    expect(client.alive?).to be(false) if client
  end

  it "brackets the transport write with request visibility callbacks" do
    client = initialized_client
    order = []
    transport.on_send do |message|
      next unless message[:method] == "session/prompt"

      order << :written
      transport.emit(
        "jsonrpc" => "2.0",
        "id" => message[:id],
        "result" => { "stopReason" => "end_turn" }
      )
    end

    client.request(
      "session/prompt",
      { "sessionId" => "session-1", "prompt" => [] },
      timeout: 1,
      before_send: -> { order << :visible },
      on_sent: -> { order << :callback }
    )

    expect(order).to eq(%i[visible written callback])
  ensure
    client&.stop
  end

  it "rolls back request visibility when the transport write fails" do
    client = initialized_client
    events = []
    transport.on_send do |message|
      raise IOError, "broken pipe" if message[:method] == "session/prompt"
    end

    expect do
      client.request(
        "session/prompt",
        {},
        timeout: 1,
        before_send: -> { events << :visible },
        on_send_error: -> { events << :rolled_back }
      )
    end.to raise_error(Clacky::Acp::Client::TransportError)

    expect(events).to eq(%i[visible rolled_back])
  ensure
    client&.stop
  end

  it "matches concurrent responses by monotonically increasing request id" do
    client = initialized_client
    transport.on_send { |_message| }

    first = Thread.new { client.request("first", { "value" => 1 }, timeout: 1) }
    second = Thread.new { client.request("second", { "value" => 2 }, timeout: 1) }

    deadline = Time.now + 1
    sleep 0.005 until transport.sent.length >= 3 || Time.now >= deadline
    requests = transport.sent.last(2)
    first_request = requests.find { |message| message[:method] == "first" }
    second_request = requests.find { |message| message[:method] == "second" }

    transport.emit("jsonrpc" => "2.0", "id" => second_request[:id], "result" => { "order" => 2 })
    transport.emit("jsonrpc" => "2.0", "id" => first_request[:id], "result" => { "order" => 1 })

    expect(first.value).to eq("order" => 1)
    expect(second.value).to eq("order" => 2)
    expect(requests.map { |message| message[:id] }.sort).to eq([2, 3])
  ensure
    client&.stop
  end

  it "routes notifications by method and session id" do
    client = initialized_client
    exact = Queue.new
    all_sessions = Queue.new

    client.on_notification("session/update", session_id: "session-1") { |params| exact << params }
    client.on_notification("session/update") { |params| all_sessions << params }

    transport.emit(
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => { "sessionId" => "session-2", "update" => { "kind" => "ignored" } }
    )
    transport.emit(
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => { "sessionId" => "session-1", "update" => { "kind" => "kept" } }
    )

    expect(exact.pop.dig("update", "kind")).to eq("kept")
    expect(all_sessions.pop.dig("update", "kind")).to eq("ignored")
    expect(all_sessions.pop.dig("update", "kind")).to eq("kept")
  ensure
    client&.stop
  end

  it "removes a notification subscription when its runtime session closes" do
    client = initialized_client
    received = Queue.new
    subscription = client.on_notification("session/update", session_id: "session-1") do |params|
      received << params
    end

    client.remove_notification_handler(subscription)
    transport.emit(
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => { "sessionId" => "session-1", "update" => { "kind" => "late" } }
    )

    expect(received).to be_empty
  ensure
    client&.stop
  end

  it "handles reverse requests without blocking normal response dispatch" do
    client = initialized_client
    transport.on_send { |_message| }
    permission_started = Queue.new
    permission_release = Queue.new

    client.on_request("session/request_permission") do |params|
      permission_started << params
      permission_release.pop
      { "outcome" => { "outcome" => "selected", "optionId" => "reject-once" } }
    end

    transport.emit(
      "jsonrpc" => "2.0",
      "id" => 90,
      "method" => "session/request_permission",
      "params" => { "sessionId" => "session-1", "toolCall" => { "toolCallId" => "tool-1" } }
    )
    expect(permission_started.pop.dig("toolCall", "toolCallId")).to eq("tool-1")

    pending = Thread.new { client.request("session/prompt", {}, timeout: 1) }
    deadline = Time.now + 1
    sleep 0.005 until transport.sent.any? { |message| message[:method] == "session/prompt" } || Time.now >= deadline
    prompt = transport.sent.find { |message| message[:method] == "session/prompt" }
    transport.emit("jsonrpc" => "2.0", "id" => prompt[:id], "result" => { "stopReason" => "end_turn" })
    expect(pending.value).to eq("stopReason" => "end_turn")

    permission_release << true
    deadline = Time.now + 1
    sleep 0.005 until transport.sent.any? { |message| message[:id] == 90 } || Time.now >= deadline
    response = transport.sent.find { |message| message[:id] == 90 }
    expect(response[:result].dig("outcome", "optionId")).to eq("reject-once")
  ensure
    permission_release << true if permission_release && permission_release.empty?
    client&.stop
  end

  it "bounds concurrent reverse requests" do
    stub_const("#{described_class}::MAX_REVERSE_REQUESTS", 1)
    client = initialized_client
    transport.on_send { |_message| }
    started = Queue.new
    release = Queue.new
    calls = 0
    lock = Mutex.new
    client.on_request("session/request_permission") do |_params|
      index = lock.synchronize { calls += 1 }
      started << index
      release.pop if index == 1
      { "outcome" => { "outcome" => "cancelled" } }
    end

    transport.emit(
      "jsonrpc" => "2.0", "id" => 90,
      "method" => "session/request_permission", "params" => {}
    )
    expect(started.pop).to eq(1)
    transport.emit(
      "jsonrpc" => "2.0", "id" => 91,
      "method" => "session/request_permission", "params" => {}
    )

    deadline = Time.now + 1
    sleep 0.005 until transport.sent.any? { |message| message[:id] == 91 } || Time.now >= deadline
    response = transport.sent.find { |message| message[:id] == 91 }
    expect(response[:error]).to include(code: -32_603)
    expect(calls).to eq(1)
  ensure
    release << true if release && release.empty?
    client&.stop
  end

  it "returns method-not-found for an unhandled reverse request" do
    client = initialized_client

    transport.emit(
      "jsonrpc" => "2.0",
      "id" => 91,
      "method" => "fs/read_text_file",
      "params" => { "path" => "/tmp/nope" }
    )

    deadline = Time.now + 1
    sleep 0.005 until transport.sent.any? { |message| message[:id] == 91 } || Time.now >= deadline
    response = transport.sent.find { |message| message[:id] == 91 }
    expect(response[:error]).to include(code: -32_601)
  ensure
    client&.stop
  end

  it "raises a protocol error with private remote details kept out of its message" do
    client = initialized_client
    transport.on_send do |message|
      next unless message[:method] == "session/new"

      transport.emit(
        "jsonrpc" => "2.0",
        "id" => message[:id],
        "error" => {
          "code" => -32_603,
          "message" => "Internal error",
          "data" => { "details" => "private remote details" }
        }
      )
    end

    expect do
      client.request("session/new", {}, timeout: 1)
    end.to raise_error(Clacky::Acp::Client::ProtocolError) do |error|
      expect(error.message).to include("session/new", "-32603")
      expect(error.message).not_to include("Internal error", "private remote details")
      expect(error.code).to eq(-32_603)
      expect(error.method).to eq("session/new")
      expect(error.remote_message).to eq("Internal error")
      expect(error.data).to eq("details" => "private remote details")
    end
  ensure
    client&.stop
  end

  it "rejects a matching response without result or error" do
    client = initialized_client
    transport.on_send do |message|
      next unless message[:method] == "session/new"

      transport.emit("jsonrpc" => "2.0", "id" => message[:id])
    end

    expect do
      client.request("session/new", {}, timeout: 1)
    end.to raise_error(Clacky::Acp::Client::ProtocolError, /invalid ACP response/i)
    expect(client.pending_request_count).to eq(0)
  ensure
    client&.stop
  end

  it "fails pending requests on a non-object protocol message" do
    client = initialized_client
    transport.on_send { |_message| }
    pending = Thread.new do
      client.request("session/prompt", {}, timeout: nil)
    rescue StandardError => e
      e
    end
    deadline = Time.now + 1
    sleep 0.005 until client.pending_request_count == 1 || Time.now >= deadline

    transport.emit(["not", "an", "object"])

    expect(pending.value).to be_a(Clacky::Acp::Client::ProtocolError)
    expect(client.alive?).to be(false)
  ensure
    client&.stop
  end

  it "fails pending requests on an unknown response id" do
    client = initialized_client
    transport.on_send { |_message| }
    pending = Thread.new do
      client.request("session/prompt", {}, timeout: nil)
    rescue StandardError => e
      e
    end
    deadline = Time.now + 1
    sleep 0.005 until client.pending_request_count == 1 || Time.now >= deadline

    transport.emit("jsonrpc" => "2.0", "id" => 999_999, "result" => {})

    expect(pending.value).to be_a(Clacky::Acp::Client::ProtocolError)
    expect(client.alive?).to be(false)
  ensure
    client&.stop
  end

  it "times out short control requests and removes their pending entry" do
    client = initialized_client
    transport.on_send { |_message| }

    expect do
      client.request("session/set_config_option", {}, timeout: 0.01)
    end.to raise_error(Clacky::Acp::Client::RequestTimeout, /session\/set_config_option/)

    expect(client.pending_request_count).to eq(0)
  ensure
    client&.stop
  end

  it "ignores a late response for a request that already timed out" do
    client = initialized_client
    transport.on_send { |_message| }

    expect do
      client.request("session/set_config_option", {}, timeout: 0.01)
    end.to raise_error(Clacky::Acp::Client::RequestTimeout)
    timed_out_id = transport.sent.last[:id]
    transport.emit("jsonrpc" => "2.0", "id" => timed_out_id, "result" => {})

    expect(client.alive?).to be(true)
  ensure
    client&.stop
  end

  it "fails all pending requests when the transport closes" do
    client = initialized_client
    transport.on_send { |_message| }
    pending = Thread.new do
      begin
        client.request("session/prompt", {}, timeout: nil)
      rescue StandardError => e
        e
      end
    end

    deadline = Time.now + 1
    sleep 0.005 until client.pending_request_count == 1 || Time.now >= deadline
    transport.emit("__transport_closed__" => true, "error" => "adapter exited")

    error = pending.value
    expect(error).to be_a(Clacky::Acp::Client::TransportError)
    expect(error.message).to include("adapter exited")
    expect(client.pending_request_count).to eq(0)
    expect(client.alive?).to be(false)
    expect do
      client.request("session/prompt", {}, timeout: nil)
    end.to raise_error(Clacky::Acp::Client::TransportError, /not initialized/)
  ensure
    client&.stop
  end

  it "sends notifications without an id and exposes redacted diagnostics from transport" do
    client = initialized_client

    client.notify("session/cancel", { "sessionId" => "session-1" })

    expect(transport.sent.last).to eq(
      jsonrpc: "2.0",
      method: "session/cancel",
      params: { "sessionId" => "session-1" }
    )
    expect(client.stderr_tail(bytes: 5)).to eq("ostic")
  ensure
    client&.stop
  end
end
