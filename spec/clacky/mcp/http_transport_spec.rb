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
end
