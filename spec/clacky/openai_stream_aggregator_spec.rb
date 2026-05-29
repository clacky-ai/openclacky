# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Clacky::OpenAIStreamAggregator do
  it "assembles a text-only stream with usage" do
    progress = []
    agg = described_class.new(on_chunk: ->(input_tokens:, output_tokens:) {
      progress << [input_tokens, output_tokens]
    })

    agg.handle({ choices: [{ index: 0, delta: { role: "assistant" } }] }.to_json)
    agg.handle({ choices: [{ index: 0, delta: { content: "Hi" } }] }.to_json)
    agg.handle({ choices: [{ index: 0, delta: { content: " there" }, finish_reason: nil }] }.to_json)
    agg.handle({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }.to_json)
    agg.handle({ choices: [], usage: { prompt_tokens: 12, completion_tokens: 2, prompt_tokens_details: { cached_tokens: 4 } } }.to_json)
    agg.handle("[DONE]")

    h = agg.to_h
    expect(h["choices"].first["message"]["content"]).to eq("Hi there")
    expect(h["choices"].first["finish_reason"]).to eq("stop")
    expect(h["usage"]["prompt_tokens"]).to eq(12)
    expect(progress.last).to eq([12, 2])
    expect(progress.size).to be >= 2
  end

  it "emits estimated output_tokens on every content delta before usage arrives" do
    progress = []
    agg = described_class.new(on_chunk: ->(input_tokens:, output_tokens:) {
      progress << [input_tokens, output_tokens]
    })

    agg.handle({ choices: [{ index: 0, delta: { content: "a" * 8 } }] }.to_json)
    agg.handle({ choices: [{ index: 0, delta: { content: "b" * 8 } }] }.to_json)

    expect(progress.size).to eq(2)
    expect(progress[0]).to eq([0, 2])
    expect(progress[1]).to eq([0, 4])
  end

  it "concatenates streamed tool_call arguments across frames" do
    agg = described_class.new

    agg.handle({
      choices: [{ index: 0, delta: {
        tool_calls: [{ index: 0, id: "call_a", type: "function", function: { name: "shell", arguments: '{"cmd' } }]
      } }]
    }.to_json)
    agg.handle({
      choices: [{ index: 0, delta: {
        tool_calls: [{ index: 0, function: { arguments: '":"ls"}' } }]
      } }]
    }.to_json)
    agg.handle({ choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] }.to_json)

    msg = agg.to_h["choices"].first["message"]
    tc = msg["tool_calls"].first
    expect(tc["id"]).to eq("call_a")
    expect(tc["function"]["name"]).to eq("shell")
    expect(tc["function"]["arguments"]).to eq('{"cmd":"ls"}')
  end

  it "ignores unparseable frames and [DONE]" do
    agg = described_class.new
    expect { agg.handle("[DONE]") }.not_to raise_error
    expect { agg.handle("not json") }.not_to raise_error
    expect(agg.to_h["choices"].first["message"]["content"]).to be_nil
  end
end
