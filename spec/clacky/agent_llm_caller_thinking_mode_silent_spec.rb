# frozen_string_literal: true

# Tests for thinking-mode silent-response detection in Agent#call_llm.
#
# Background (root cause tracked in memory `openclacky-deepseek-openrouter-fixes`):
#
#   DeepSeek V4 / Kimi K2 and other reasoning models can spend all output
#   tokens inside `reasoning_content` and emit `content=""` + no tool_calls
#   + finish_reason="stop". Protocol-legal under OpenAI semantics, but
#   semantically the model "thought and went silent" — agent main loop
#   would treat it as a completed task and exit. Symptom user sees:
#   conversation freezes mid-task with no error.
#
#   Detector lives in LlmCaller#call_llm right after empty_response_detected.
#   It raises RetryableError so the standard retry + fallback path applies.

RSpec.describe Clacky::Agent, "thinking-mode silent response recovery" do
  let(:config) do
    Clacky::AgentConfig.new(
      models: [{
        "type"             => "default",
        "model"            => "dsk-deepseek-v4-pro",
        "api_key"          => "absk-test",
        "base_url"         => "https://api.deepseek.com/v1",
        "anthropic_format" => false
      }],
      permission_mode: :auto_approve
    )
  end

  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      allow(c).to receive(:instance_variable_get).with(:@api_key).and_return("absk-test")
      allow(c).to receive(:bedrock?).and_return(false)
      allow(c).to receive(:anthropic_format?).and_return(false)
      allow(c).to receive(:supports_prompt_caching?).and_return(false)
      allow(c).to receive(:format_tool_results) do |_resp, tool_results, **_|
        tool_results.map { |r| { role: "tool", tool_call_id: r[:id], content: r[:content] } }
      end
    end
  end

  let(:agent) do
    described_class.new(
      client, config,
      working_dir: Dir.pwd,
      ui: nil,
      profile: "general",
      session_id: Clacky::SessionManager.generate_id,
      source: :manual
    )
  end

  before do
    allow_any_instance_of(described_class).to receive(:sleep)
    Thread.current[:lang] = "en"
  end

  describe 'content="" + tool_calls=nil + reasoning_content non-empty + finish_reason="stop"' do
    it "retries and succeeds instead of silently exiting" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        if call_count == 1
          mock_api_response(
            content: "",
            tool_calls: nil,
            finish_reason: "stop",
            reasoning_content: "Now update the corresponding data cells. 🤖 OK"
          )
        else
          mock_api_response(content: "Done.")
        end
      end

      result = agent.run("modify the page")
      expect(result[:status]).to eq(:success)
      expect(call_count).to be >= 2
    end
  end

  describe 'content="" + tool_calls=[] (empty array) + reasoning_content non-empty + finish_reason="stop"' do
    it "retries and succeeds (treats empty array same as nil)" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        if call_count == 1
          mock_api_response(
            content: "",
            tool_calls: [],
            finish_reason: "stop",
            reasoning_content: "Let me think about this..."
          )
        else
          mock_api_response(content: "Done.")
        end
      end

      result = agent.run("modify the page")
      expect(result[:status]).to eq(:success)
      expect(call_count).to be >= 2
    end
  end

  describe "negative: content non-empty + reasoning_content non-empty (legitimate completion)" do
    it "does NOT retry; treats it as normal task completion" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        mock_api_response(
          content: "Here is the answer.",
          tool_calls: nil,
          finish_reason: "stop",
          reasoning_content: "I considered the options and decided X."
        )
      end

      agent.run("explain something")
      expect(call_count).to eq(1)
    end
  end

  describe "negative: content empty + reasoning_content empty (no thinking happened)" do
    it "does NOT retry; legitimate empty-but-stopped response stays out of this detector" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        mock_api_response(
          content: "",
          tool_calls: nil,
          finish_reason: "stop",
          reasoning_content: nil
        )
      end

      agent.run("ping")
      expect(call_count).to eq(1)
    end
  end

  describe "negative: content empty + tool_calls present + reasoning_content non-empty" do
    it "does NOT retry; the tool_call path is the primary signal of progress" do
      Dir.mktmpdir do |dir|
        tmp = File.join(dir, "ok.txt")
        call_count = 0
        allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
          call_count += 1
          if call_count == 1
            mock_api_response(
              content: "",
              tool_calls: [{
                id: "call_thinking_ok",
                type: "function",
                name: "write",
                arguments: JSON.generate(path: tmp, content: "hi")
              }],
              finish_reason: "tool_calls",
              reasoning_content: "I should write this file."
            )
          else
            mock_api_response(content: "Done.")
          end
        end

        result = agent.run("write file")
        expect(result[:status]).to eq(:success)
        expect(File.exist?(tmp)).to be true
        expect(call_count).to eq(2)
      end
    end
  end

  describe "runaway protection: persistent silent thinking never recovers" do
    it "eventually raises AgentError after exhausting retries (no infinite loop)" do
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        mock_api_response(
          content: "",
          tool_calls: nil,
          finish_reason: "stop",
          reasoning_content: "Hmm, thinking forever..."
        )
      end

      expect {
        Timeout.timeout(10) { agent.run("modify the page") }
      }.to raise_error(Clacky::AgentError, /Service unavailable|empty content/i)
    end
  end
end
