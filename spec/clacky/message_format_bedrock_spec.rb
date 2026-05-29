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
end
