# frozen_string_literal: true

# Integration-level tests for the fallback model state machine inside Agent#call_llm.
# We wire up a real Agent (with stubbed Client) and simulate 503 / 429 / network
# failures to verify the three states: primary_ok → fallback_active → probing → primary_ok.

RSpec.describe Clacky::Agent, "fallback model integration" do
  # ── shared helpers ─────────────────────────────────────────────────────────

  let(:primary_model)  { "abs-claude-sonnet-4-6" }
  let(:fallback_model) { "abs-claude-sonnet-4-5" }

  # Config that maps to openclacky provider so fallback_model_for works
  let(:config) do
    Clacky::AgentConfig.new(
      models: [
        {
          "type"             => "default",
          "model"            => primary_model,
          "api_key"          => "clacky-test-key",
          "base_url"         => "https://api.openclacky.com/v1",
          "anthropic_format" => true
        }
      ],
      permission_mode: :auto_approve
    )
  end

  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "clacky-test-key")
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

  # Shorthand: a successful API response with no tool calls
  def ok_response(content: "All good")
    mock_api_response(content: content)
  end

  # Simulate a 503 / 429-style retryable error
  def retryable_error(msg = "Service Unavailable (503)")
    Clacky::RetryableError.new(msg)
  end

  # ── Scenario 1: 3 consecutive failures trigger fallback switch ─────────────

  describe "Scenario 1 — primary fails 3 times, then fallback succeeds" do
    before do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, model:, **_opts|
        call_count += 1
        if call_count <= Clacky::Agent::LlmCaller::RETRIES_BEFORE_FALLBACK
          raise retryable_error
        else
          # After switching to fallback, succeed immediately
          ok_response
        end
      end
    end

    it "completes successfully" do
      result = agent.run("Hello")
      expect(result[:status]).to eq(:success)
    end

    it "switches config to :fallback_active" do
      agent.run("Hello")
      expect(config.fallback_active?).to be true
    end

    it "uses the fallback model for successful call" do
      models_used = []
      switched = false
      allow(client).to receive(:send_messages_with_tools) do |_msgs, model:, **_opts|
        models_used << model
        # Fail until fallback is activated, then succeed
        if !switched && !config.fallback_active?
          raise retryable_error
        else
          switched = true
          ok_response
        end
      end

      agent.run("Hello")
      expect(models_used.last).to eq(fallback_model)
    end
  end

  # ── Scenario 2: probing — primary recovers after cooling-off ──────────────

  describe "Scenario 2 — cooling-off expires, probing succeeds, switches back to primary" do
    before do
      # Start already in fallback state with expired cooling-off
      config.activate_fallback!(fallback_model)
      config.instance_variable_set(:@fallback_since, Time.now - 31 * 60)
    end

    it "uses primary model during probing" do
      probing_model = nil
      allow(client).to receive(:send_messages_with_tools) do |_msgs, model:, **_opts|
        probing_model = model
        ok_response
      end

      agent.run("Hello")
      expect(probing_model).to eq(primary_model)
    end

    it "resets state to primary_ok after successful probe" do
      allow(client).to receive(:send_messages_with_tools).and_return(ok_response)

      agent.run("Hello")
      expect(config.fallback_active?).to be false
      expect(config.probing?).to be false
      expect(config.effective_model_name).to eq(primary_model)
    end
  end

  # ── Scenario 3: probing fails → renew cooling-off, retry with fallback ─────

  describe "Scenario 3 — probing fails, cooling-off renews, falls back to fallback model" do
    before do
      config.activate_fallback!(fallback_model)
      config.instance_variable_set(:@fallback_since, Time.now - 31 * 60)
    end

    it "completes successfully using fallback after probe failure" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, model:, **_opts|
        call_count += 1
        if call_count == 1
          # First call: probing with primary → fail
          raise retryable_error("Primary still down")
        else
          # Subsequent calls: fallback model → succeed
          ok_response
        end
      end

      result = agent.run("Hello")
      expect(result[:status]).to eq(:success)
    end

    it "stays in :fallback_active after probe failure" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, model:, **_opts|
        call_count += 1
        raise retryable_error if call_count == 1
        ok_response
      end

      agent.run("Hello")
      expect(config.fallback_active?).to be true
      expect(config.probing?).to be false
    end

    it "renews the cooling-off timestamp after probe failure" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, model:, **_opts|
        call_count += 1
        raise retryable_error if call_count == 1
        ok_response
      end

      agent.run("Hello")
      ts = config.instance_variable_get(:@fallback_since)
      # Should have been renewed (close to now, not 31 min ago)
      expect(ts).to be_within(5).of(Time.now)
    end
  end

  # ── Scenario 4: no fallback configured → exhausts retries ─────────────────

  describe "Scenario 4 — no fallback model configured, primary keeps failing" do
    let(:config) do
      # Use a provider with no fallback_models mapping
      Clacky::AgentConfig.new(
        models: [
          {
            "type"             => "default",
            "model"            => "gpt-4o",
            "api_key"          => "sk-test",
            "base_url"         => "https://api.openai.com/v1",
            "anthropic_format" => false
          }
        ],
        permission_mode: :auto_approve
      )
    end

    before do
      allow(client).to receive(:send_messages_with_tools).and_raise(retryable_error)
    end

    it "raises AgentError after max retries" do
      expect { agent.run("Hello") }.to raise_error(Clacky::AgentError, /unavailable after/)
    end

    it "never enters fallback_active" do
      begin
        agent.run("Hello")
      rescue Clacky::AgentError
        nil
      end
      expect(config.fallback_active?).to be false
    end
  end
end
