# frozen_string_literal: true

require "spec_helper"
require "clacky/mcp/http_transport"

RSpec.describe Clacky::Mcp::HttpTransport do
  # Helper: build a transport instance without a real HTTP server
  def build_transport
    described_class.new(name: "test", url: "http://127.0.0.1:9999/mcp")
  end

  # Helper: call the private consume_sse with a fake response that
  # yields the given chunks, then collect all delivered messages.
  def consume_chunks(transport, chunks)
    messages = []
    transport.on_message { |m| messages << m }

    fake_res = double("Net::HTTPResponse")
    allow(fake_res).to receive(:read_body) do |&blk|
      chunks.each { |c| blk.call(c) }
    end

    transport.send(:consume_sse, fake_res)
    messages
  end

  describe "#consume_sse – line ending normalization" do
    let(:transport) { build_transport }
    let(:payload)   { { "jsonrpc" => "2.0", "id" => 1, "result" => { "ok" => true } } }
    let(:json)      { JSON.generate(payload) }

    context "when server uses \\n\\n (standard)" do
      it "delivers the message" do
        chunks = ["data: #{json}\n\n"]
        expect(consume_chunks(transport, chunks)).to eq([payload])
      end
    end

    context "when server uses \\r\\n\\r\\n (FastMCP / Windows-style)" do
      it "delivers the message" do
        chunks = ["data: #{json}\r\n\r\n"]
        expect(consume_chunks(transport, chunks)).to eq([payload])
      end
    end

    context "when server uses \\r\\r (old Mac-style)" do
      it "delivers the message" do
        chunks = ["data: #{json}\r\r"]
        expect(consume_chunks(transport, chunks)).to eq([payload])
      end
    end

    context "when \\r\\n is split across two chunks" do
      it "still delivers the message" do
        # chunk boundary falls inside "\r\n\r\n"
        # e.g. chunk1 ends with "\r\n\r" and chunk2 starts with "\n"
        full = "data: #{json}\r\n\r\n"
        split_at = full.length - 1
        chunks = [full[0...split_at], full[split_at..]]
        expect(consume_chunks(transport, chunks)).to eq([payload])
      end
    end

    context "when \\r\\n is split exactly in the middle (\\r | \\n)" do
      it "still delivers the message" do
        # chunk1: "data: {...}\r", chunk2: "\ndata: {...}\r\n" would be
        # for a two-event stream; here we test the simpler single-event split
        full = "data: #{json}\r\n\r\n"
        # split after the first \r
        chunks = [full[0...full.index("\r") + 1], full[full.index("\r") + 1..]]
        expect(consume_chunks(transport, chunks)).to eq([payload])
      end
    end

    context "when a CRLF between two data lines is split across chunks" do
      it "keeps both lines in one event" do
        # The payload only parses when both data lines land in the same
        # event: normalizing each chunk in isolation turns "\r" | "\n"
        # into "\n\n", splitting the event in two and corrupting both halves.
        line1 = '{"jsonrpc": "2.0",'
        line2 = ' "id": 1, "result": {"ok": true}}'
        full  = "data: #{line1}\r\ndata: #{line2}\r\n\r\n"
        split_at = full.index("\r") + 1
        chunks = [full[0...split_at], full[split_at..]]
        expect(consume_chunks(transport, chunks)).to eq([payload])
      end
    end

    context "when a \\r\\r separator is split across chunks at end of stream" do
      it "delivers the message" do
        full = "data: #{json}\r\r"
        chunks = [full[0...-1], full[-1..]]
        expect(consume_chunks(transport, chunks)).to eq([payload])
      end
    end

    context "when multiple events arrive in one chunk" do
      let(:payload2) { { "jsonrpc" => "2.0", "id" => 2, "result" => { "ok" => false } } }
      let(:json2)    { JSON.generate(payload2) }

      it "delivers all messages" do
        chunks = ["data: #{json}\r\n\r\ndata: #{json2}\r\n\r\n"]
        expect(consume_chunks(transport, chunks)).to eq([payload, payload2])
      end
    end

    context "when events are spread across many small chunks" do
      it "delivers the message" do
        full = "data: #{json}\r\n\r\n"
        # split into individual bytes
        chunks = full.chars
        expect(consume_chunks(transport, chunks)).to eq([payload])
      end
    end
  end

  describe "OAuth authorization" do
    class FakeAuthorization
      attr_reader :invalidations

      def initialize
        @invalidations = 0
      end

      def authorization_headers
        { "Authorization" => "Bearer protected-token" }
      end

      def invalidate!
        @invalidations += 1
      end
    end

    def response(status, body: "", headers: {})
      instance_double("Net::HTTPResponse").tap do |res|
        allow(res).to receive(:code).and_return(status.to_s)
        allow(res).to receive(:[]).with(anything) do |key|
          headers[key.to_s.downcase] || headers[key.to_s]
        end
        allow(res).to receive(:read_body).and_return(body)
      end
    end

    it "injects OAuth headers without mutating static headers" do
      authorization = FakeAuthorization.new
      requests = []
      requester = lambda do |request, &block|
        requests << request
        block.call(response(202))
      end
      transport = described_class.new(
        name: "oauth",
        url: "https://example.com/mcp",
        headers: { "X-Static" => "yes" },
        authorization: authorization,
        requester: requester
      )

      transport.send(:dispatch_post, '{"id":1}', is_request: true)

      expect(requests.first["Authorization"]).to eq("Bearer protected-token")
      expect(requests.first["X-Static"]).to eq("yes")
    end

    it "invalidates and retries exactly once after a 401" do
      authorization = FakeAuthorization.new
      attempts = 0
      requester = lambda do |_request, &block|
        attempts += 1
        block.call(response(attempts == 1 ? 401 : 202))
      end
      transport = described_class.new(
        name: "oauth", url: "https://example.com/mcp",
        authorization: authorization, requester: requester
      )

      transport.send(:dispatch_post, '{"id":1}', is_request: true)

      expect(attempts).to eq(2)
      expect(authorization.invalidations).to eq(1)
    end

    it "does not retry a second 401 or expose its response body" do
      authorization = FakeAuthorization.new
      attempts = 0
      requester = lambda do |_request, &block|
        attempts += 1
        block.call(response(401, body: "protected-token"))
      end
      transport = described_class.new(
        name: "oauth", url: "https://example.com/mcp",
        authorization: authorization, requester: requester
      )

      expect do
        transport.send(:dispatch_post, '{"id":1}', is_request: true)
      end.to raise_error(Clacky::Mcp::Transport::TransportError) { |error|
        expect(error.message).to include("HTTP 401")
        expect(error.message).not_to include("protected-token")
      }
      expect(attempts).to eq(2)
      expect(authorization.invalidations).to eq(1)
    end

    it "preserves a capped response body for non-401 errors" do
      diagnostic = "validation failed: #{'x' * 600}"
      requester = lambda do |_request, &block|
        block.call(response(422, body: diagnostic))
      end
      transport = described_class.new(
        name: "oauth", url: "https://example.com/mcp",
        authorization: FakeAuthorization.new, requester: requester
      )

      expect do
        transport.send(:dispatch_post, '{"id":1}', is_request: true)
      end.to raise_error(Clacky::Mcp::Transport::TransportError) { |error|
        expect(error.message).to include("HTTP 422")
        expect(error.message).to include(diagnostic[0, 500])
        expect(error.message).not_to include(diagnostic[0, 501])
      }
    end
  end
end
