# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::MessageFormat::Anthropic do
  describe ".parse_response" do
    it "extracts text content from response blocks" do
      data = {
        "content" => [
          { "type" => "text", "text" => "Hello world" }
        ],
        "usage" => { "input_tokens" => 10, "output_tokens" => 5 },
        "stop_reason" => "end_turn"
      }

      result = described_class.parse_response(data)
      expect(result[:content]).to eq("Hello world")
      expect(result[:reasoning_content]).to be_nil
    end

    it "extracts thinking blocks as reasoning_content" do
      data = {
        "content" => [
          { "type" => "thinking", "thinking" => "Let me analyze this..." },
          { "type" => "text", "text" => "The answer is 42." }
        ],
        "usage" => { "input_tokens" => 10, "output_tokens" => 15 },
        "stop_reason" => "end_turn"
      }

      result = described_class.parse_response(data)
      expect(result[:content]).to eq("The answer is 42.")
      expect(result[:reasoning_content]).to eq("Let me analyze this...")
    end

    it "joins multiple thinking blocks" do
      data = {
        "content" => [
          { "type" => "thinking", "thinking" => "First thought." },
          { "type" => "thinking", "thinking" => "Second thought." },
          { "type" => "text", "text" => "Done." }
        ],
        "usage" => { "input_tokens" => 5, "output_tokens" => 10 },
        "stop_reason" => "end_turn"
      }

      result = described_class.parse_response(data)
      expect(result[:reasoning_content]).to eq("First thought.Second thought.")
    end

    it "omits reasoning_content when no thinking blocks present" do
      data = {
        "content" => [
          { "type" => "text", "text" => "Just text." }
        ],
        "usage" => { "input_tokens" => 5, "output_tokens" => 3 },
        "stop_reason" => "end_turn"
      }

      result = described_class.parse_response(data)
      expect(result).not_to have_key(:reasoning_content)
    end
  end

  describe ".build_request_body" do
    let(:model) { "claude-sonnet-4" }
    let(:tools) { [] }
    let(:max_tokens) { 1024 }

    it "parses well-formed tool_call arguments into structured input" do
      messages = [
        {
          role: "assistant",
          content: "",
          tool_calls: [
            {
              id: "call_1",
              function: { name: "shell", arguments: '{"cmd":"ls"}' }
            }
          ]
        }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      block = body[:messages].first[:content].find { |b| b[:type] == "tool_use" }

      expect(block[:input]).to eq({ "cmd" => "ls" })
    end

    # Regression: a previous task can leave a truncated/invalid `arguments`
    # string in session.json (upstream SSE cut mid-stream, oversized JSON, etc.).
    # Replaying that history must NOT crash the agent on startup — we degrade
    # to an empty input so the conversation can continue and the model can
    # self-correct from the tool_result that follows.
    it "degrades to empty input when tool_call arguments are truncated JSON" do
      truncated = '{"path":"/tmp/x.py","content":"print(\\"hi'
      messages = [
        {
          role: "assistant",
          content: "",
          tool_calls: [
            {
              id: "call_truncated",
              function: { name: "write", arguments: truncated }
            }
          ]
        }
      ]

      expect {
        body = described_class.build_request_body(messages, model, tools, max_tokens, false)
        block = body[:messages].first[:content].find { |b| b[:type] == "tool_use" }
        expect(block[:input]).to eq({})
        expect(block[:name]).to eq("write")
        expect(block[:id]).to eq("call_truncated")
      }.not_to raise_error
    end

    it "passes through pre-parsed Hash arguments without re-parsing" do
      messages = [
        {
          role: "assistant",
          content: "",
          tool_calls: [
            {
              id: "call_2",
              function: { name: "shell", arguments: { "cmd" => "ls" } }
            }
          ]
        }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      block = body[:messages].first[:content].find { |b| b[:type] == "tool_use" }

      expect(block[:input]).to eq({ "cmd" => "ls" })
    end
  end
end
