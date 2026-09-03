# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Clacky::OpenAIResponsesStreamAggregator do
  let(:agg) { described_class.new }

  describe "text streaming" do
    it "accumulates text deltas" do
      events = [
        { "type" => "response.output_text.delta", "delta" => "Hello" },
        { "type" => "response.output_text.delta", "delta" => ", " },
        { "type" => "response.output_text.delta", "delta" => "world!" }
      ]
      events.each { |e| agg.handle(JSON.generate(e)) }

      result = agg.to_h
      expect(result["output"][0]["content"][0]["text"]).to eq("Hello, world!")
      expect(result["output"][0]["type"]).to eq("message")
    end

    it "sets status to completed on response.completed" do
      agg.handle(JSON.generate({ "type" => "response.output_text.delta", "delta" => "Hi" }))
      agg.handle(JSON.generate({
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [],
          "usage" => { "input_tokens" => 5, "output_tokens" => 2 }
        }
      }))

      expect(agg.saw_done?).to be true
      expect(agg.to_h["status"]).to eq("completed")
    end

    it "sets status to incomplete on response.incomplete" do
      agg.handle(JSON.generate({ "type" => "response.incomplete" }))
      expect(agg.saw_done?).to be true
      expect(agg.to_h["status"]).to eq("incomplete")
    end

    it "captures incomplete_details from response.incomplete" do
      event = {
        "type" => "response.incomplete",
        "response" => {
          "status" => "incomplete",
          "incomplete_details" => { "reason" => "content_filter" }
        }
      }
      agg.handle(JSON.generate(event))
      expect(agg.to_h["status"]).to eq("incomplete")
      expect(agg.to_h["incomplete_details"]).to eq({ "reason" => "content_filter" })
    end

    it "omits incomplete_details key when provider sends none" do
      agg.handle(JSON.generate({ "type" => "response.incomplete" }))
      expect(agg.to_h).not_to have_key("incomplete_details")
    end

    it "sets status to completed on response.done (OpenAI official terminal event)" do
      agg.handle(JSON.generate({
        "type" => "response.done",
        "response" => {
          "status" => "completed",
          "output" => [],
          "usage" => { "input_tokens" => 5, "output_tokens" => 2 }
        }
      }))

      expect(agg.saw_done?).to be true
      expect(agg.to_h["status"]).to eq("completed")
      expect(agg.to_h["usage"]).to eq("input_tokens" => 5, "output_tokens" => 2)
    end
  end

  describe "reasoning streaming" do
    it "accumulates reasoning deltas and emits them in to_h" do
      events = [
        { "type" => "response.reasoning.delta", "delta" => "Thinking..." },
        { "type" => "response.reasoning.delta", "delta" => " more." }
      ]
      events.each { |e| agg.handle(JSON.generate(e)) }

      reasoning = agg.to_h["output"].find { |o| o["type"] == "reasoning" }
      expect(reasoning).not_to be_nil
      expect(reasoning["content"]).to eq([{ "type" => "reasoning_text", "text" => "Thinking... more." }])
    end

    it "accumulates reasoning deltas from response.reasoning_text.delta (OpenAI official / DeepSeek)" do
      agg.handle(JSON.generate({ "type" => "response.reasoning_text.delta", "delta" => "Thinking..." }))

      reasoning = agg.to_h["output"].find { |o| o["type"] == "reasoning" }
      expect(reasoning).not_to be_nil
      expect(reasoning["content"]).to eq([{ "type" => "reasoning_text", "text" => "Thinking..." }])
    end

    it "omits the reasoning item when no reasoning was streamed" do
      agg.handle(JSON.generate({ "type" => "response.output_text.delta", "delta" => "plain" }))

      expect(agg.to_h["output"].map { |o| o["type"] }).to eq(["message"])
    end
  end

  describe "function call streaming" do
    it "accumulates function call argument deltas" do
      events = [
        {
          "type" => "response.output_item.added",
          "item" => {
            "type" => "function_call",
            "id" => "fc_001",
            "call_id" => "call_abc",
            "name" => "get_weather",
            "arguments" => ""
          }
        },
        { "type" => "response.function_call_arguments.delta", "item_id" => "fc_001", "delta" => "{\"city\":" },
        { "type" => "response.function_call_arguments.delta", "item_id" => "fc_001", "delta" => "\"Tokyo\"}" }
      ]
      events.each { |e| agg.handle(JSON.generate(e)) }

      result = agg.to_h
      fc = result["output"].find { |o| o["type"] == "function_call" }
      expect(fc).not_to be_nil
      expect(fc["call_id"]).to eq("call_abc")
      expect(fc["name"]).to eq("get_weather")
      expect(fc["arguments"]).to eq("{\"city\":\"Tokyo\"}")
    end

    it "uses complete arguments from output_item.done when available" do
      events = [
        {
          "type" => "response.output_item.added",
          "item" => {
            "type" => "function_call",
            "id" => "fc_001",
            "call_id" => "call_abc",
            "name" => "get_weather",
            "arguments" => ""
          }
        },
        { "type" => "response.function_call_arguments.delta", "item_id" => "fc_001", "delta" => "partial" },
        {
          "type" => "response.output_item.done",
          "item" => {
            "type" => "function_call",
            "call_id" => "call_abc",
            "name" => "get_weather",
            "arguments" => "{\"city\":\"Paris\"}"
          }
        }
      ]
      events.each { |e| agg.handle(JSON.generate(e)) }

      result = agg.to_h
      fc = result["output"].find { |o| o["type"] == "function_call" }
      expect(fc["arguments"]).to eq("{\"city\":\"Paris\"}")
    end

    it "handles multiple function calls with different item_ids" do
      events = [
        {
          "type" => "response.output_item.added",
          "item" => { "type" => "function_call", "id" => "fc_001", "call_id" => "call_a", "name" => "tool_a", "arguments" => "" }
        },
        {
          "type" => "response.output_item.added",
          "item" => { "type" => "function_call", "id" => "fc_002", "call_id" => "call_b", "name" => "tool_b", "arguments" => "" }
        },
        { "type" => "response.function_call_arguments.delta", "item_id" => "fc_001", "delta" => "A" },
        { "type" => "response.function_call_arguments.delta", "item_id" => "fc_002", "delta" => "B" }
      ]
      events.each { |e| agg.handle(JSON.generate(e)) }

      result = agg.to_h
      fcs = result["output"].select { |o| o["type"] == "function_call" }
      expect(fcs.length).to eq(2)
      expect(fcs[0]["arguments"]).to eq("A")
      expect(fcs[1]["arguments"]).to eq("B")
    end
  end

  describe "sync_from_final_output" do
    it "syncs text from response.completed when no incremental events were seen" do
      agg.handle(JSON.generate({
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [
            {
              "type" => "message",
              "role" => "assistant",
              "content" => [{ "type" => "output_text", "text" => "Synced text" }]
            }
          ],
          "usage" => { "input_tokens" => 10, "output_tokens" => 5 }
        }
      }))

      result = agg.to_h
      expect(result["output"][0]["content"][0]["text"]).to eq("Synced text")
    end

    it "does not override incremental text with sync" do
      agg.handle(JSON.generate({ "type" => "response.output_text.delta", "delta" => "Incremental" }))
      agg.handle(JSON.generate({
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [
            { "type" => "message", "content" => [{ "type" => "output_text", "text" => "Should not override" }] }
          ],
          "usage" => {}
        }
      }))

      result = agg.to_h
      expect(result["output"][0]["content"][0]["text"]).to eq("Incremental")
    end

    it "backfills only what incremental tracking missed" do
      # Text arrived via deltas, but the function call only shows up in the
      # final response (provider skipped function_call incremental events).
      agg.handle(JSON.generate({ "type" => "response.output_text.delta", "delta" => "Hi" }))
      agg.handle(JSON.generate({
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [
            { "type" => "message", "content" => [{ "type" => "output_text", "text" => "complete text" }] },
            { "type" => "function_call", "call_id" => "call_1", "name" => "get_weather", "arguments" => "{\"city\":\"Paris\"}" }
          ],
          "usage" => { "input_tokens" => 5, "output_tokens" => 2 }
        }
      }))

      h = agg.to_h
      expect(h["output"][0]["content"][0]["text"]).to eq("Hi")
      expect(h["output"][1]["type"]).to eq("function_call")
      expect(h["output"][1]["call_id"]).to eq("call_1")
      expect(h["output"][1]["arguments"]).to eq("{\"city\":\"Paris\"}")
    end

    it "backfills reasoning from a top-level reasoning item when no delta was seen" do
      payload = {
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [
            { "type" => "reasoning", "content" => [{ "type" => "reasoning_text", "text" => "Let me think." }] },
            { "type" => "message", "content" => [{ "type" => "output_text", "text" => "Answer" }] }
          ],
          "usage" => {}
        }
      }
      agg.handle(JSON.generate(payload))

      output = agg.to_h["output"]
      reasoning = output.find { |o| o["type"] == "reasoning" }
      message = output.find { |o| o["type"] == "message" }
      expect(reasoning["content"]).to eq([{ "type" => "reasoning_text", "text" => "Let me think." }])
      expect(message["content"]).to eq([{ "type" => "output_text", "text" => "Answer" }])
    end

    it "backfills reasoning from an OpenAI-style reasoning block inside the message item" do
      payload = {
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [
            {
              "type" => "message",
              "content" => [
                {
                  "type" => "reasoning",
                  "content" => [{ "type" => "reasoning_text", "text" => "Step by step." }],
                  "summary" => []
                },
                { "type" => "output_text", "text" => "Answer" }
              ]
            }
          ],
          "usage" => {}
        }
      }
      agg.handle(JSON.generate(payload))

      reasoning = agg.to_h["output"].find { |o| o["type"] == "reasoning" }
      expect(reasoning["content"]).to eq([{ "type" => "reasoning_text", "text" => "Step by step." }])
    end

    it "falls back to summary_text when the reasoning block carries no full text" do
      payload = {
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [
            {
              "type" => "message",
              "content" => [
                { "type" => "reasoning", "summary" => [{ "type" => "summary_text", "text" => "Brief summary." }] },
                { "type" => "output_text", "text" => "Answer" }
              ]
            }
          ],
          "usage" => {}
        }
      }
      agg.handle(JSON.generate(payload))

      reasoning = agg.to_h["output"].find { |o| o["type"] == "reasoning" }
      expect(reasoning["content"]).to eq([{ "type" => "reasoning_text", "text" => "Brief summary." }])
    end

    it "keeps incremental reasoning deltas over the final snapshot" do
      agg.handle(JSON.generate({ "type" => "response.reasoning_text.delta", "delta" => "Live reasoning" }))
      payload = {
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [
            { "type" => "reasoning", "content" => [{ "type" => "reasoning_text", "text" => "Snapshot reasoning" }] },
            { "type" => "message", "content" => [{ "type" => "output_text", "text" => "Answer" }] }
          ],
          "usage" => {}
        }
      }
      agg.handle(JSON.generate(payload))

      reasoning = agg.to_h["output"].find { |o| o["type"] == "reasoning" }
      expect(reasoning["content"]).to eq([{ "type" => "reasoning_text", "text" => "Live reasoning" }])
    end
  end

  describe "usage tracking" do
    it "emits progress callback with token counts on response.completed" do
      progress_calls = []
      agg = described_class.new(on_chunk: ->(input_tokens:, output_tokens:) {
        progress_calls << [input_tokens, output_tokens]
      })

      agg.handle(JSON.generate({ "type" => "response.output_text.delta", "delta" => "Hello" }))
      agg.handle(JSON.generate({
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [],
          "usage" => { "input_tokens" => 50, "output_tokens" => 10 }
        }
      }))

      # At least one call with the final usage
      expect(progress_calls.last).to eq([50, 10])
    end
  end

  describe "error handling" do
    it "counts parse failures without crashing" do
      agg.handle("not valid json{{{")
      agg.handle(JSON.generate({ "type" => "response.output_text.delta", "delta" => "Hi" }))

      expect(agg.parse_failures).to eq(1)
      expect(agg.frames_seen).to eq(2)
      result = agg.to_h
      expect(result["output"][0]["content"][0]["text"]).to eq("Hi")
    end

    it "silently ignores [DONE] sentinel without counting as parse failure" do
      agg.handle(JSON.generate({ "type" => "response.output_text.delta", "delta" => "Hi" }))
      agg.handle("[DONE]")

      expect(agg.parse_failures).to eq(0)
      expect(agg.frames_seen).to eq(2)
    end
  end

  describe "saw_done?" do
    it "returns false before any terminal event" do
      expect(agg.saw_done?).to be false
    end

    it "returns true after response.completed" do
      agg.handle(JSON.generate({ "type" => "response.completed", "response" => { "status" => "completed", "output" => [] } }))
      expect(agg.saw_done?).to be true
    end

    it "returns true after response.incomplete" do
      agg.handle(JSON.generate({ "type" => "response.incomplete" }))
      expect(agg.saw_done?).to be true
    end
  end

  describe "to_h shape" do
    it "returns empty output when no events processed" do
      result = agg.to_h
      expect(result["output"]).to eq([])
      expect(result["status"]).to eq("completed")
      expect(result["usage"]).to eq({})
    end

    it "includes usage from response.completed" do
      usage = { "input_tokens" => 100, "output_tokens" => 50 }
      agg.handle(JSON.generate({
        "type" => "response.completed",
        "response" => { "status" => "completed", "output" => [], "usage" => usage }
      }))

      expect(agg.to_h["usage"]).to eq(usage)
    end
  end
end
