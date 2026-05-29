# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Clacky::AnthropicStreamAggregator do
  it "assembles a text-only stream into an Anthropic-shaped response" do
    progress_events = []
    agg = described_class.new(on_chunk: ->(input_tokens:, output_tokens:) {
      progress_events << [input_tokens, output_tokens]
    })

    agg.handle("message_start", {
      message: { usage: { input_tokens: 12, output_tokens: 0 } }
    }.to_json)
    agg.handle("content_block_start", {
      index: 0, content_block: { type: "text", text: "" }
    }.to_json)
    agg.handle("content_block_delta", {
      index: 0, delta: { type: "text_delta", text: "Hi " }
    }.to_json)
    agg.handle("content_block_delta", {
      index: 0, delta: { type: "text_delta", text: "there" }
    }.to_json)
    agg.handle("content_block_stop", { index: 0 }.to_json)
    agg.handle("message_delta", {
      delta: { stop_reason: "end_turn" }, usage: { output_tokens: 5 }
    }.to_json)
    agg.handle("message_stop", {}.to_json)

    result = agg.to_h
    expect(result["content"]).to eq([{ "type" => "text", "text" => "Hi there" }])
    expect(result["stop_reason"]).to eq("end_turn")
    expect(result["usage"]["input_tokens"]).to eq(12)
    expect(result["usage"]["output_tokens"]).to eq(5)
    expect(progress_events.first).to eq([12, 0])
    expect(progress_events.last).to eq([12, 5])
  end

  it "concatenates streamed tool_use input_json_delta fragments and parses JSON" do
    agg = described_class.new

    agg.handle("content_block_start", {
      index: 0,
      content_block: { type: "tool_use", id: "toolu_1", name: "shell", input: {} }
    }.to_json)
    agg.handle("content_block_delta", {
      index: 0, delta: { type: "input_json_delta", partial_json: '{"command":"echo' }
    }.to_json)
    agg.handle("content_block_delta", {
      index: 0, delta: { type: "input_json_delta", partial_json: ' hi"}' }
    }.to_json)
    agg.handle("content_block_stop", { index: 0 }.to_json)

    block = agg.to_h["content"].first
    expect(block["type"]).to eq("tool_use")
    expect(block["id"]).to eq("toolu_1")
    expect(block["name"]).to eq("shell")
    expect(block["input"]).to eq("command" => "echo hi")
  end

  it "passes parse_response through to canonical usage shape" do
    agg = described_class.new
    agg.handle("message_start", {
      message: { usage: { input_tokens: 100, cache_read_input_tokens: 50, output_tokens: 0 } }
    }.to_json)
    agg.handle("content_block_start", { index: 0, content_block: { type: "text", text: "" } }.to_json)
    agg.handle("content_block_delta", { index: 0, delta: { type: "text_delta", text: "ok" } }.to_json)
    agg.handle("message_delta", { delta: { stop_reason: "end_turn" }, usage: { output_tokens: 7 } }.to_json)

    parsed = Clacky::MessageFormat::Anthropic.parse_response(agg.to_h)
    expect(parsed[:content]).to eq("ok")
    expect(parsed[:finish_reason]).to eq("stop")
    expect(parsed[:usage][:prompt_tokens]).to eq(150)
    expect(parsed[:usage][:completion_tokens]).to eq(7)
    expect(parsed[:usage][:cache_read_input_tokens]).to eq(50)
  end

  it "ignores ping events and unparseable payloads" do
    agg = described_class.new
    expect { agg.handle("ping", {}.to_json) }.not_to raise_error
    expect { agg.handle("content_block_delta", "not json") }.not_to raise_error
    expect(agg.to_h["content"]).to eq([])
  end
end
