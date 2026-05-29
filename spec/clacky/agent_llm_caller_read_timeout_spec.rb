# frozen_string_literal: true

# Tests for the read-timeout handling in Agent#call_llm.
#
# Motivation: a Faraday::TimeoutError on our non-streaming LLM POST almost
# always means the model was asked to produce too much output in one shot
# (e.g. "write me a 2000-line snake game") and the response never finished
# within the 300s read-timeout. Blindly retrying the same request reproduces
# the same timeout, so on the FIRST timeout in a task we inject a [SYSTEM]
# user message asking the model to break the work into smaller steps.
#
# These tests cover:
#   - Connection-level errors (ConnectionFailed, ECONNREFUSED) do NOT inject
#     the hint — they are infrastructure blips, the model did nothing wrong.
#   - The FIRST TimeoutError in a task injects exactly one hint message.
#   - Subsequent TimeoutErrors in the SAME task do NOT inject additional hints.
#   - Starting a new task (Agent#run a second time) resets the flag so the
#     hint can be injected again if the new task also times out.

RSpec.describe Clacky::Agent, "read-timeout hint injection" do
  let(:config) do
    Clacky::AgentConfig.new(
      models: [
        {
          "type"             => "default",
          "model"            => "abs-claude-sonnet-4-6",
          "api_key"          => "absk-test",
          "base_url"         => "https://api.openclacky.com/v1",
          "anthropic_format" => true
        }
      ],
      permission_mode: :auto_approve
    )
  end

  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "absk-test")
      allow(c).to receive(:bedrock?).and_return(false)
      allow(c).to receive(:anthropic_format?).and_return(true)
      allow(c).to receive(:supports_prompt_caching?).and_return(false)
      allow(c).to receive(:format_tool_results).and_return([])
    end
  end

  let(:agent) do
    described_class.new(
      client, config,
      working_dir: Dir.pwd,
      ui: nil,
      profile: "coding",
      session_id: Clacky::SessionManager.generate_id,
      source: :manual
    )
  end

  before do
    # Suppress sleep in retry loops so tests run fast
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  # Count [SYSTEM]-prefixed, system_injected user messages in history
  def count_timeout_hints(agent)
    agent.instance_variable_get(:@history).to_a.count do |m|
      m[:role] == "user" && m[:system_injected] == true &&
        m[:content].to_s.include?("The previous LLM response timed out")
    end
  end

  # ── ConnectionFailed path (infrastructure blip, should NOT inject hint) ───

  describe "Faraday::ConnectionFailed" do
    it "retries without injecting the timeout hint" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        if call_count == 1
          raise Faraday::ConnectionFailed, "connection refused"
        else
          mock_api_response(content: "Done")
        end
      end

      result = agent.run("hi")
      expect(result[:status]).to eq(:success)
      expect(count_timeout_hints(agent)).to eq(0)
    end
  end

  # ── TimeoutError path — FIRST occurrence should inject hint ───────────────

  describe "Faraday::TimeoutError (first occurrence in a task)" do
    it "injects the 'break into smaller steps' hint exactly once, then succeeds" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        raise Faraday::TimeoutError, "read timeout reached" if call_count == 1

        mock_api_response(content: "Done")
      end

      result = agent.run("write me a 2000-line snake game")
      expect(result[:status]).to eq(:success)
      expect(count_timeout_hints(agent)).to eq(1)
    end

    it "marks the injected hint as system_injected (hidden from UI/caching)" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        raise Faraday::TimeoutError, "read timeout" if call_count == 1

        mock_api_response(content: "Done")
      end

      agent.run("big task")
      hint = agent.instance_variable_get(:@history).to_a.find do |m|
        m[:role] == "user" && m[:content].to_s.include?("timed out")
      end
      expect(hint[:system_injected]).to be true
    end
  end

  # ── TimeoutError — multiple in same task should NOT re-inject ─────────────

  describe "multiple Faraday::TimeoutError in the same task" do
    it "injects the hint only once, regardless of how many timeouts occur" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        # First 3 calls time out; 4th succeeds
        raise Faraday::TimeoutError, "read timeout ##{call_count}" if call_count <= 3

        mock_api_response(content: "Done")
      end

      result = agent.run("huge task")
      expect(result[:status]).to eq(:success)
      expect(count_timeout_hints(agent)).to eq(1)
    end
  end

  # ── Starting a new task resets the flag ───────────────────────────────────

  describe "new task resets the injection flag" do
    it "can inject the hint again on a subsequent task that also times out" do
      # Task 1: one timeout, then success
      # Task 2: one timeout, then success
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        # Call 1 (task 1) → timeout
        # Call 2 (task 1) → success
        # Call 3 (task 2) → timeout
        # Call 4 (task 2) → success
        raise Faraday::TimeoutError, "read timeout" if [1, 3].include?(call_count)

        mock_api_response(content: "Done #{call_count}")
      end

      agent.run("task 1")
      expect(count_timeout_hints(agent)).to eq(1)

      agent.run("task 2")
      expect(count_timeout_hints(agent)).to eq(2)
    end
  end

  # ── Exhausts retry budget if timeouts never stop ──────────────────────────

  describe "TimeoutError exceeding max retries" do
    it "raises AgentError mentioning timeout after exhausting the retry budget" do
      allow(client).to receive(:send_messages_with_tools)
        .and_raise(Faraday::TimeoutError.new("read timeout"))

      expect { agent.run("impossible task") }
        .to raise_error(Clacky::AgentError, /timed out after/i)
    end
  end
end
