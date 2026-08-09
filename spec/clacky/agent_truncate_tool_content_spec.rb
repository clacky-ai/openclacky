# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Agent, "#truncate_oversized_tool_content" do
  let(:client) do
    instance_double(Clacky::Client).tap { |c| c.instance_variable_set(:@api_key, "k") }
  end
  let(:config) do
    c = Clacky::AgentConfig.new(permission_mode: :auto_approve)
    c.add_model(model: "claude-sonnet-4.5", api_key: "k", base_url: "https://api.anthropic.com")
    c
  end
  let(:agent) do
    described_class.new(client, config, working_dir: Dir.pwd, ui: nil,
                        profile: "coding", session_id: Clacky::SessionManager.generate_id, source: :manual)
  end

  def truncate(msg, tool_name: nil)
    agent.send(:truncate_oversized_tool_content, msg, tool_name: tool_name)
  end

  describe "terminal output (head + tail)" do
    let(:content) { "X" * 200_000 }
    let(:msg) { { role: "tool", tool_call_id: "abc", content: content } }

    it "preserves both the first 40k and the last 40k" do
      result = truncate(msg, tool_name: "terminal")
      written = result[:content]

      # Head portion
      expect(written).to start_with("X" * 40_000)
      # Tail portion
      expect(written).to end_with("X" * 40_000)
      # Omitted chars notice
      omitted = 200_000 - 40_000 - 40_000
      expect(written).to include("#{omitted} chars omitted")
    end

    it "keeps total result well under 100k chars" do
      result = truncate(msg, tool_name: "terminal")
      # 40k head + 40k tail + notice (~300 chars) should be well under 100k
      expect(result[:content].length).to be < 81_000
    end
  end

  describe "non-terminal output (head only)" do
    let(:content) { "Y" * 200_000 }
    let(:msg) { { role: "tool", tool_call_id: "abc", content: content } }

    it "keeps only the first 80k with a standard truncation notice" do
      result = truncate(msg, tool_name: "grep")
      written = result[:content]

      expect(written).to start_with("Y" * 80_000)
      expect(written).to include("showing first 80000")
      # No tail content
      expect(written).not_to include("chars omitted")
    end

    it "applies head-only when tool_name is nil" do
      result = truncate(msg)
      expect(result[:content]).to start_with("Y" * 80_000)
    end
  end

  describe "short results" do
    it "leaves short terminal results untouched" do
      msg = { role: "tool", tool_call_id: "x", content: "exit code 0\nbuild succeeded" }
      result = truncate(msg, tool_name: "terminal")
      expect(result[:content]).to eq("exit code 0\nbuild succeeded")
    end

    it "leaves short non-terminal results untouched" do
      msg = { role: "tool", tool_call_id: "x", content: "found 3 matches" }
      result = truncate(msg, tool_name: "grep")
      expect(result[:content]).to eq("found 3 matches")
    end
  end

  describe "non-string content" do
    it "leaves array content (image blocks) untouched" do
      content = [{ type: "image_url", image_url: { url: "data:..." } }]
      msg = { role: "tool", tool_call_id: "x", content: content }
      result = truncate(msg, tool_name: "file_reader")
      expect(result[:content]).to eq(content)
    end
  end
end
