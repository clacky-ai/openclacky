# frozen_string_literal: true

require "spec_helper"
require "clacky/client"

# Guards the streaming truncation detector: a complete chat-completion stream
# always terminates with finish_reason (OpenAI) / stop_reason (Anthropic). When
# the upstream cuts the stream mid-response without emitting that terminal
# frame, Faraday may not raise — leaving a silently truncated message. The
# client must convert this into a retryable UpstreamTruncatedError instead of
# handing the half-written answer to the agent.
RSpec.describe Clacky::Client, "streaming truncation detection" do
  let(:on_chunk) { proc {} }

  def fake_200
    Struct.new(:status, :body, :env, :headers).new(200, "", Struct.new(:body).new(""), {})
  end

  # Stub the given connection so its on_data proc receives the supplied SSE
  # chunks (one frame per chunk), then returns a 200 response.
  def stub_stream(conn_ivar, client, sse_frames)
    req_stub = double("faraday_request", headers: {})
    allow(req_stub).to receive(:body=)
    options = double("faraday_options")
    allow(req_stub).to receive(:options).and_return(options)
    allow(options).to receive(:on_data=) do |proc_|
      sse_frames.each { |frame| proc_.call(frame, frame.bytesize, nil) }
    end

    conn = instance_double(Faraday::Connection)
    allow(conn).to receive(:post).and_yield(req_stub).and_return(fake_200)
    client.instance_variable_set(conn_ivar, conn)
  end

  describe "OpenAI stream" do
    let(:client) { described_class.new("k", base_url: "https://api.example.com", model: "gpt-4") }

    def frame(json)
      "data: #{json}\n\n"
    end

    it "raises UpstreamTruncatedError when the stream ends without finish_reason" do
      frames = [
        frame('{"choices":[{"index":0,"delta":{"role":"assistant"}}]}'),
        frame('{"choices":[{"index":0,"delta":{"content":"half written"}}]}')
      ]
      stub_stream(:@openai_connection, client, frames)

      expect {
        client.send(:send_openai_stream_request, { model: "gpt-4" }, on_chunk)
      }.to raise_error(Clacky::UpstreamTruncatedError, /without finish_reason/)
    end

    it "does not raise when the stream terminates with finish_reason" do
      frames = [
        frame('{"choices":[{"index":0,"delta":{"content":"done"}}]}'),
        frame('{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}'),
        frame('{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}')
      ]
      stub_stream(:@openai_connection, client, frames)

      result = client.send(:send_openai_stream_request, { model: "gpt-4" }, on_chunk)
      expect(result[:finish_reason]).to eq("stop")
      expect(result[:content]).to eq("done")
    end

    it "treats finish_reason as terminal even when the upstream omits the usage frame" do
      frames = [
        frame('{"choices":[{"index":0,"delta":{"content":"ok"}}]}'),
        frame('{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}')
      ]
      stub_stream(:@openai_connection, client, frames)

      expect {
        client.send(:send_openai_stream_request, { model: "gpt-4" }, on_chunk)
      }.not_to raise_error
    end
  end

  describe "Anthropic stream" do
    let(:client) do
      described_class.new("sk-ant", base_url: "https://api.anthropic.com",
                                    model: "claude-sonnet-4.6", anthropic_format: true)
    end

    def frame(event, json)
      "event: #{event}\ndata: #{json}\n\n"
    end

    it "raises UpstreamTruncatedError when the stream ends without stop_reason" do
      frames = [
        frame("message_start", '{"message":{"usage":{"input_tokens":10,"output_tokens":0}}}'),
        frame("content_block_start", '{"index":0,"content_block":{"type":"text"}}'),
        frame("content_block_delta", '{"index":0,"delta":{"type":"text_delta","text":"half"}}')
      ]
      stub_stream(:@anthropic_connection, client, frames)

      expect {
        client.send(:send_anthropic_stream_request, { model: "claude-sonnet-4.6" }, on_chunk)
      }.to raise_error(Clacky::UpstreamTruncatedError, /without stop_reason/)
    end

    it "does not raise when the stream terminates with stop_reason" do
      frames = [
        frame("message_start", '{"message":{"usage":{"input_tokens":10,"output_tokens":0}}}'),
        frame("content_block_start", '{"index":0,"content_block":{"type":"text"}}'),
        frame("content_block_delta", '{"index":0,"delta":{"type":"text_delta","text":"done"}}'),
        frame("message_delta", '{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}')
      ]
      stub_stream(:@anthropic_connection, client, frames)

      result = client.send(:send_anthropic_stream_request, { model: "claude-sonnet-4.6" }, on_chunk)
      expect(result[:finish_reason]).to eq("stop")
    end
  end

  describe "Bedrock stream" do
    let(:client) do
      described_class.new("clacky-key", base_url: "https://api.openclacky.com",
                                        model: "abs-claude-opus-4-7")
    end

    def frame(event, json)
      "event: #{event}\ndata: #{json}\n\n"
    end

    it "raises UpstreamTruncatedError when the stream ends without stopReason" do
      frames = [
        frame("messageStart", '{"role":"assistant"}'),
        frame("contentBlockDelta", '{"contentBlockIndex":0,"delta":{"text":"half"}}')
      ]
      stub_stream(:@bedrock_connection, client, frames)

      expect {
        client.send(:send_bedrock_stream_request, { model: "abs-claude-opus-4-7" }, "abs-claude-opus-4-7", on_chunk)
      }.to raise_error(Clacky::UpstreamTruncatedError, /without stopReason/)
    end

    it "does not raise when the stream terminates with stopReason" do
      frames = [
        frame("messageStart", '{"role":"assistant"}'),
        frame("contentBlockDelta", '{"contentBlockIndex":0,"delta":{"text":"done"}}'),
        frame("messageStop", '{"stopReason":"end_turn"}'),
        frame("metadata", '{"usage":{"inputTokens":5,"outputTokens":1}}')
      ]
      stub_stream(:@bedrock_connection, client, frames)

      result = client.send(:send_bedrock_stream_request, { model: "abs-claude-opus-4-7" }, "abs-claude-opus-4-7", on_chunk)
      expect(result[:finish_reason]).to eq("stop")
    end
  end
end
