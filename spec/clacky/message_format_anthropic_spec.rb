# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::MessageFormat::Anthropic do
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

  describe ".sanitize_tool_use_id" do
    it "passes through ids that already match Anthropic's pattern" do
      expect(described_class.sanitize_tool_use_id("toolu_01ABCdef-XYZ")).to eq("toolu_01ABCdef-XYZ")
    end

    it "replaces colons (kimi-k2.6 style 'tool_name:idx' ids) with underscore" do
      expect(described_class.sanitize_tool_use_id("file_reader:0")).to eq("file_reader_0")
    end

    it "replaces any other illegal char with underscore" do
      expect(described_class.sanitize_tool_use_id("a.b/c@d e")).to eq("a_b_c_d_e")
    end

    it "truncates to 128 chars" do
      long = "a" * 200
      expect(described_class.sanitize_tool_use_id(long).length).to eq(128)
    end

    it "coerces non-string input" do
      expect(described_class.sanitize_tool_use_id(nil)).to eq("")
      expect(described_class.sanitize_tool_use_id(42)).to eq("42")
    end
  end

  describe "tool_use / tool_result id sanitization in build_request_body" do
    let(:model) { "claude-sonnet-4" }
    let(:tools) { [] }
    let(:max_tokens) { 1024 }

    it "sanitizes assistant tool_use ids and matches them with tool_result ids" do
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

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)

      use_block    = body[:messages][0][:content].find { |b| b[:type] == "tool_use" }
      result_block = body[:messages][1][:content].find { |b| b[:type] == "tool_result" }

      expect(use_block[:id]).to eq("file_reader_0")
      expect(result_block[:tool_use_id]).to eq("file_reader_0")
      expect(use_block[:id]).to match(/\A[a-zA-Z0-9_-]+\z/)
    end
  end
end
