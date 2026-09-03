# frozen_string_literal: true

require "spec_helper"
require "clacky/client"

# Regression guard for the OpenAI Responses API send path
# (send_openai_responses_request + send_openai_responses_stream_request).
#
# Maintainer review (PR #490) flagged that this core path had zero coverage,
# which is why the streaming-reasoning loss and a NameError slipped past CI.
# These specs exercise request-body building/sending and both response paths:
#
#   - non-streaming 200 JSON response -> canonical result with reasoning
#   - streaming SSE frames (incl. reasoning deltas) -> canonical result
#   - streaming without a terminal event -> UpstreamTruncatedError
RSpec.describe Clacky::Client, "OpenAI Responses API send path" do
  let(:api_key) { "sk-or-v1-testkey" }
  let(:base_url) { "https://openrouter.ai/api/v1" }

  def fake_ok(body = "")
    Struct.new(:status, :body, :env).new(200, body, Struct.new(:body).new(""))
  end

  def build_client(model = "deepseek/deepseek-v4-pro")
    described_class.new(api_key, base_url: base_url, model: model,
                                 api_format: "openai-responses")
  end

  def messages
    [{ role: "user", content: "Hi" }]
  end

  # Stub @openai_connection so req.body is captured and (when streaming) the
  # on_data proc receives the supplied SSE chunks, then a 200 is returned.
  def stub_connection(client, sse_frames = nil, response_body: "")
    capture = { body: nil }
    req_stub = double("faraday_request", headers: {})
    allow(req_stub).to receive(:body=) { |json| capture[:body] = json }
    options = double("faraday_options")
    allow(req_stub).to receive(:options).and_return(options)
    allow(options).to receive(:on_data=) do |proc_|
      sse_frames&.each { |frame| proc_.call(frame, frame.bytesize, nil) }
    end

    conn = instance_double(Faraday::Connection)
    allow(conn).to receive(:post).and_yield(req_stub).and_return(fake_ok(response_body))
    client.instance_variable_set(:@openai_connection, conn)
    capture
  end

  def sse(json)
    "data: #{json}\n\n"
  end

  describe "non-streaming send_openai_responses_request" do
    it "builds a Responses API request body and sends it to /responses" do
      client = build_client
      capture = stub_connection(client, response_body: {
        "status" => "completed",
        "output" => [
          { "type" => "message", "content" => [{ "type" => "output_text", "text" => "Hello" }] }
        ],
        "usage" => { "input_tokens" => 10, "output_tokens" => 5 }
      }.to_json)

      result = client.send_openai_responses_request(messages, "deepseek/deepseek-v4-pro", [], 32, false)

      body = JSON.parse(capture[:body])
      expect(body["model"]).to eq("deepseek/deepseek-v4-pro")
      expect(body["max_output_tokens"]).to be >= 32
      expect(body["input"]).to be_an(Array)
      expect(body["input"].first["role"]).to eq("user")
      expect(body["input"].first["type"]).to eq("message")
      expect(result[:content]).to eq("Hello")
      expect(result[:finish_reason]).to eq("stop")
    end

    it "extracts reasoning from a top-level reasoning item (DeepSeek shape)" do
      client = build_client
      stub_connection(client, response_body: {
        "status" => "completed",
        "output" => [
          { "type" => "reasoning", "content" => [{ "type" => "reasoning_text", "text" => "Let me think." }] },
          { "type" => "message", "content" => [{ "type" => "output_text", "text" => "Answer" }] }
        ],
        "usage" => {}
      }.to_json)

      result = client.send_openai_responses_request(messages, "deepseek/deepseek-v4-pro", [], 32, false)

      expect(result[:content]).to eq("Answer")
      expect(result[:reasoning_content]).to eq("Let me think.")
    end
  end

  describe "streaming send_openai_responses_request (on_chunk given)" do
    it "reassembles text and reasoning deltas into the canonical result" do
      client = build_client
      frames = [
        sse('{"type":"response.reasoning_text.delta","delta":"Thinking..."}'),
        sse('{"type":"response.output_text.delta","delta":"Answer"}'),
        sse('{"type":"response.completed","response":{"status":"completed","output":[],' \
            '"usage":{"input_tokens":7,"output_tokens":2}}}')
      ]
      stub_connection(client, frames)
      on_chunk = proc { |**| nil }

      result = client.send_openai_responses_request(
        messages, "deepseek/deepseek-v4-pro", [], 32, false, on_chunk: on_chunk
      )

      expect(result[:content]).to eq("Answer")
      expect(result[:reasoning_content]).to eq("Thinking...")
      expect(result[:finish_reason]).to eq("stop")
      expect(result[:usage][:prompt_tokens]).to eq(7)
    end

    it "raises UpstreamTruncatedError when the stream ends without a terminal event" do
      client = build_client
      frames = [
        sse('{"type":"response.output_text.delta","delta":"half"}')
      ]
      stub_connection(client, frames)
      on_chunk = proc { |**| nil }

      expect do
        client.send_openai_responses_request(
          messages, "deepseek/deepseek-v4-pro", [], 32, false, on_chunk: on_chunk
        )
      end.to raise_error(Clacky::UpstreamTruncatedError, /response.completed/)
    end
  end
end
