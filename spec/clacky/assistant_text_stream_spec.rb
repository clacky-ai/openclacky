# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "clacky/json_ui_controller"
require "clacky/server/web_ui_controller"
require "clacky/server/http_server"

RSpec.describe "optional assistant text streaming" do
  providers = {
    Clacky::OpenAIStreamAggregator => [
      [{ choices: [{ delta: { content: "你" } }] }.to_json],
      [{ choices: [{ delta: { reasoning_content: "private" } }] }.to_json],
      [{ choices: [{ delta: { content: "好" } }] }.to_json]
    ],
    Clacky::AnthropicStreamAggregator => [
      ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "你" } }.to_json],
      ["content_block_delta", { index: 1, delta: { type: "thinking_delta", thinking: "private" } }.to_json],
      ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "好" } }.to_json]
    ],
    Clacky::BedrockStreamAggregator => [
      ["contentBlockDelta", { contentBlockIndex: 0, delta: { text: "你" } }.to_json],
      ["contentBlockDelta", { contentBlockIndex: 1, delta: { reasoningContent: { text: "private" } } }.to_json],
      ["contentBlockDelta", { contentBlockIndex: 0, delta: { text: "好" } }.to_json]
    ],
    Clacky::OpenAIResponsesStreamAggregator => [
      [{ type: "response.output_text.delta", delta: "你" }.to_json],
      [{ type: "response.reasoning_text.delta", delta: "private" }.to_json],
      [{ type: "response.output_text.delta", delta: "好" }.to_json]
    ]
  }

  providers.each do |provider, frames|
    it "streams only public text and preserves the #{provider} aggregate" do
      text = []
      streamed = provider.new(on_text_delta: ->(delta) { text << delta })
      legacy = provider.new
      frames.each { |args| streamed.handle(*args); legacy.handle(*args) }
      expect(text).to eq(["你", "好"])
      expect(streamed.to_h).to eq(legacy.to_h)
    end

    it "isolates preview callback failures for #{provider}" do
      streamed = provider.new(on_text_delta: ->(_delta) { raise "UI unavailable" })
      legacy = provider.new
      frames.each { |args| streamed.handle(*args); legacy.handle(*args) }
      expect(streamed.to_h).to eq(legacy.to_h)
    end
  end

  def json_events(output)
    output.string.lines.map { |line| JSON.parse(line) }
  end

  it "leaves legacy NDJSON output unchanged unless explicitly enabled" do
    output = StringIO.new
    ui = Clacky::JsonUIController.new(output: output)
    expect(ui.stream_assistant_text?).to eq(false)
    ui.show_assistant_delta(message_id: "m", seq: 1, delta: "Hi")
    ui.end_assistant_stream(message_id: "m")
    ui.show_assistant_message("Hi", files: [])
    expect(json_events(output)).to eq([{ "type" => "assistant_message", "content" => "Hi" }])
  end

  def streaming_agent(ui)
    agent = Object.new.extend(Clacky::Agent::LlmCaller)
    agent.instance_variable_set(:@ui, ui)
    agent
  end

  it "flushes buffered text before ending the preview and keeps the final event unchanged" do
    output = StringIO.new
    ui = Clacky::JsonUIController.new(output: output, stream: true)
    agent = streaming_agent(ui)
    allow(Process).to receive(:clock_gettime).and_return(100.0)
    result = agent.send(:with_assistant_text_stream) do |callback|
      callback.call("你")
      callback.call("好")
      callback.call("！")
      :response
    end
    ui.show_assistant_message("你好！", files: [])
    events = json_events(output)
    deltas = events.select { |e| e["type"] == "assistant_message_delta" }
    expect(result).to eq(:response)
    expect(deltas.map { |e| e["delta"] }).to eq(["你", "好！"])
    expect(deltas.map { |e| e["seq"] }).to eq([1, 2])
    expect(events[-2]).to eq({ "type" => "assistant_message_stream_end", "message_id" => deltas.first["message_id"] })
    expect(events.last).to eq({ "type" => "assistant_message", "content" => "你好！" })
  end

  it "closes interrupted previews and assigns retries a new ID" do
    output = StringIO.new
    agent = streaming_agent(Clacky::JsonUIController.new(output: output, stream: true))
    expect {
      agent.send(:with_assistant_text_stream) do |callback|
        callback.call("partial")
        raise Clacky::AgentInterrupted
      end
    }.to raise_error(Clacky::AgentInterrupted)
    agent.send(:with_assistant_text_stream) { |callback| callback.call("retry") }
    events = json_events(output)
    expect(events.map { |e| e["type"] }).to eq(%w[assistant_message_delta assistant_message_stream_end assistant_message_delta assistant_message_stream_end])
    expect(events[0]["message_id"]).to eq(events[1]["message_id"])
    expect(events[2]["message_id"]).to eq(events[3]["message_id"])
    expect(events[0]["message_id"]).not_to eq(events[2]["message_id"])
  end

  it "does not enable previews for legacy UIs" do
    agent = streaming_agent(Object.new)
    expect(agent.send(:with_assistant_text_stream) { |callback| callback }).to be_nil
  end

  describe "reply-only streaming through the agent" do
    let(:output) { StringIO.new }
    let(:ui) { Clacky::JsonUIController.new(output: output, stream: true) }
    let(:config) do
      Clacky::AgentConfig.new(
        models: [{ "type" => "default", "model" => "gpt-4", "api_key" => "test",
                   "base_url" => "https://api.example.com/v1" }],
        permission_mode: :auto_approve
      )
    end
    let(:client) { Clacky::Client.new("test", base_url: "https://api.example.com/v1", model: "gpt-4") }
    let(:agent) do
      Clacky::Agent.new(client, config, working_dir: Dir.pwd, ui: ui, profile: "coding",
                       session_id: Clacky::SessionManager.generate_id, source: :manual)
    end
    let(:callbacks) { [] }

    before do
      allow(client).to receive(:send_messages_with_tools) do |_messages, **opts|
        callbacks << opts[:on_text_delta]
        opts[:on_text_delta]&.call("answer")
        opts[:on_chunk].call(input_tokens: 10, output_tokens: 2)
        mock_api_response(content: "answer")
      end
    end

    it "streams normal replies" do
      allow(agent).to receive(:compress_messages_if_needed).and_return(nil)
      agent.send(:think)
      expect(callbacks.first).to be_a(Proc)
      expect(json_events(output).select { |e| e["type"] == "assistant_message_delta" }
        .map { |e| e["delta"] }).to eq(["answer"])
    end

    it "suppresses compression text while preserving token progress" do
      context = {
        compression_message: { role: "user", content: "Summarize", system_injected: true },
        original_token_count: 100, original_message_count: 10, compression_level: 1
      }
      allow(agent).to receive(:compress_messages_if_needed).and_return(context)
      allow(agent).to receive(:handle_compression_response)
      agent.send(:think)
      expect(callbacks).to eq([nil])
      events = json_events(output)
      expect(events.none? { |e| e["type"].start_with?("assistant_message") }).to eq(true)
      expect(events).to include(hash_including("type" => "progress"))
    end

    it "keeps direct internal calls silent by default" do
      agent.send(:call_llm)
      expect(callbacks).to eq([nil])
    end
  end

  it "negotiates streaming per connection and resets it when omitted on resubscribe" do
    server = Clacky::Server::HttpServer.allocate
    registry = double("registry", ensure: true, get: nil, snapshot: nil)
    allow(registry).to receive(:with_session).and_yield({})
    server.instance_variable_set(:@registry, registry)
    server.instance_variable_set(:@agent_config, double("config", input_behavior: "queue"))
    server.instance_variable_set(:@ws_mutex, Mutex.new)
    server.instance_variable_set(:@ws_clients, {})
    conn = Clacky::Server::HttpServer::WebSocketConnection.allocate
    allow(conn).to receive(:send_json).and_return(true)

    server.on_ws_message(conn, { type: "subscribe", session_id: "s", stream: true }.to_json)
    expect(conn.stream_assistant_text).to eq(true)
    server.on_ws_message(conn, { type: "subscribe", session_id: "s" }.to_json)
    expect(conn.stream_assistant_text).to eq(false)
    server.on_ws_message(conn, { type: "subscribe", session_id: "s", stream: "true" }.to_json)
    expect(conn.stream_assistant_text).to eq(false)
  end

  it "sends transient events only to opted-in connections, preserving full messages for both" do
    server = Clacky::Server::HttpServer.allocate
    old_conn = double("legacy", closed?: false, send_json: true)
    new_conn = double("streaming", closed?: false, send_json: true, stream_assistant_text: true)
    server.instance_variable_set(:@ws_mutex, Mutex.new)
    server.instance_variable_set(:@ws_clients, { "s" => [old_conn, new_conn] })
    ui = Clacky::Server::WebUIController.new("s", ->(sid, event) { server.broadcast(sid, event) })
    expect(old_conn).not_to receive(:send_json).with(hash_including(type: "assistant_message_delta"))
    expect(old_conn).not_to receive(:send_json).with(hash_including(type: "assistant_message_stream_end"))
    expect(new_conn).to receive(:send_json).with(hash_including(type: "assistant_message_delta", session_id: "s", delta: "Hi"))
    expect(new_conn).to receive(:send_json).with(hash_including(type: "assistant_message_stream_end"))
    [old_conn, new_conn].each do |conn|
      expect(conn).to receive(:send_json).with(hash_including(type: "assistant_message", content: "Hi"))
    end
    ui.show_assistant_delta(message_id: "m", seq: 1, delta: "Hi")
    ui.end_assistant_stream(message_id: "m")
    ui.show_assistant_message("Hi", files: [])
  end
end
