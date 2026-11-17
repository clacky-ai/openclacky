# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::MessageFormat::Bedrock do
  describe "tool_use / tool_result id sanitization" do
    let(:model)      { "anthropic.claude-sonnet-4-v1:0" }
    let(:tools)      { [] }
    let(:max_tokens) { 1024 }

    it "sanitizes toolUseId on both assistant toolUse and user toolResult" do
      messages = [
        {
          role: "assistant",
          content: "",
          tool_calls: [
            { id: "file_reader:0", function: { name: "file_reader", arguments: "{}" } }
          ]
        },
        { role: "tool", tool_call_id: "file_reader:0", content: "ok" }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens)

      use_block    = body[:messages][0][:content].find { |b| b[:toolUse] }
      result_block = body[:messages][1][:content].find { |b| b[:toolResult] }

      expect(use_block[:toolUse][:toolUseId]).to eq("file_reader_0")
      expect(result_block[:toolResult][:toolUseId]).to eq("file_reader_0")
      expect(use_block[:toolUse][:toolUseId]).to match(/\A[a-zA-Z0-9_-]+\z/)
    end
  end

  describe "role alternation" do
    let(:model)      { "anthropic.claude-sonnet-4-v1:0" }
    let(:tools)      { [] }
    let(:max_tokens) { 1024 }

    it "merges injected user messages that pile up before the user's own turn" do
      messages = [
        { role: "user", content: "question" },
        { role: "assistant", content: "", tool_calls: [{ id: "c1", function: { name: "terminal", arguments: "{}" } }] },
        { role: "tool", tool_call_id: "c1", content: "output" },
        { role: "assistant", content: "done" },
        { role: "user", content: "[Session context: today is ...]" },
        { role: "user", content: "## Previous Session Archives" },
        { role: "user", content: "<system-reminder>memories</system-reminder>" },
        { role: "user", content: "继续" }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens)

      roles = body[:messages].map { |m| m[:role] }
      expect(roles).to eq(%w[user assistant user assistant user])
      expect(body[:messages].last[:content].map { |b| b[:text] }).to eq(
        ["[Session context: today is ...]", "## Previous Session Archives",
         "<system-reminder>memories</system-reminder>", "继续"]
      )
    end

    it "keeps toolResult blocks ahead of merged text" do
      messages = [
        { role: "assistant", content: "", tool_calls: [
          { id: "c1", function: { name: "terminal", arguments: "{}" } },
          { id: "c2", function: { name: "terminal", arguments: "{}" } }
        ] },
        { role: "tool", tool_call_id: "c1", content: "output" },
        { role: "tool", tool_call_id: "c2", content: "output2" },
        { role: "user", content: "继续" }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens)

      expect(body[:messages].size).to eq(2)
      blocks = body[:messages].last[:content]
      expect(blocks.count { |b| b[:toolResult] }).to eq(2)
      expect(blocks.last[:text]).to eq("继续")
    end
  end

  describe "reasoning effort injection" do
    let(:messages)   { [{ role: "user", content: "hi" }] }
    let(:tools)      { [] }
    let(:max_tokens) { 1024 }

    it "sends thinking/output_config for Claude models" do
      body = described_class.build_request_body(
        messages, "abs-claude-sonnet-5", tools, max_tokens, false, reasoning_effort: "high"
      )

      expect(body[:additionalModelRequestFields]).to eq(
        { thinking: { type: "adaptive" }, output_config: { effort: "high" } }
      )
    end

    it "omits them for non-Anthropic Converse models such as Gemini 3.1 Pro" do
      body = described_class.build_request_body(
        messages, "or-gemini-3-1-pro", tools, max_tokens, false, reasoning_effort: "high"
      )

      expect(body).not_to have_key(:additionalModelRequestFields)
    end
  end
end
