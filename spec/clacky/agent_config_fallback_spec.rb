# frozen_string_literal: true

RSpec.describe Clacky::AgentConfig, "fallback state machine" do
  # Minimal config with an openclacky-style base_url so fallback_model_for works
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
      ]
    )
  end

  # ── initial state ──────────────────────────────────────────────────────────

  describe "initial state" do
    it "has no fallback active" do
      expect(config.fallback_active?).to be false
    end

    it "is not probing" do
      expect(config.probing?).to be false
    end

    it "returns the primary model as effective_model_name" do
      expect(config.effective_model_name).to eq("abs-claude-sonnet-4-6")
    end
  end

  # ── activate_fallback! ─────────────────────────────────────────────────────

  describe "#activate_fallback!" do
    before { config.activate_fallback!("abs-claude-sonnet-4-5") }

    it "marks fallback as active" do
      expect(config.fallback_active?).to be true
    end

    it "is not probing yet" do
      expect(config.probing?).to be false
    end

    it "returns fallback model as effective_model_name" do
      expect(config.effective_model_name).to eq("abs-claude-sonnet-4-5")
    end

    it "records fallback_since timestamp" do
      ts = config.instance_variable_get(:@fallback_since)
      expect(ts).to be_within(2).of(Time.now)
    end
  end

  # ── maybe_start_probing ────────────────────────────────────────────────────

  describe "#maybe_start_probing" do
    context "when in :primary_ok state" do
      it "is a no-op" do
        config.maybe_start_probing
        expect(config.fallback_active?).to be false
        expect(config.probing?).to be false
      end
    end

    context "when cooling-off has NOT expired" do
      before do
        config.activate_fallback!("abs-claude-sonnet-4-5")
        # Pretend activated just 1 minute ago
        config.instance_variable_set(:@fallback_since, Time.now - 60)
      end

      it "stays in :fallback_active" do
        config.maybe_start_probing
        expect(config.probing?).to be false
        expect(config.fallback_active?).to be true
      end

      it "still serves fallback model" do
        config.maybe_start_probing
        expect(config.effective_model_name).to eq("abs-claude-sonnet-4-5")
      end
    end

    context "when cooling-off has expired (30 min passed)" do
      before do
        config.activate_fallback!("abs-claude-sonnet-4-5")
        config.instance_variable_set(:@fallback_since, Time.now - 31 * 60)
      end

      it "transitions to :probing" do
        config.maybe_start_probing
        expect(config.probing?).to be true
      end

      it "fallback_active? returns true while probing" do
        config.maybe_start_probing
        expect(config.fallback_active?).to be true
      end

      it "serves PRIMARY model when probing (silent test)" do
        config.maybe_start_probing
        expect(config.effective_model_name).to eq("abs-claude-sonnet-4-6")
      end
    end
  end

  # ── confirm_fallback_ok! ───────────────────────────────────────────────────

  describe "#confirm_fallback_ok!" do
    context "when probing and primary responds successfully" do
      before do
        config.activate_fallback!("abs-claude-sonnet-4-5")
        config.instance_variable_set(:@fallback_since, Time.now - 31 * 60)
        config.maybe_start_probing  # → :probing
        config.confirm_fallback_ok!
      end

      it "resets fallback_active? to false" do
        expect(config.fallback_active?).to be false
      end

      it "resets probing? to false" do
        expect(config.probing?).to be false
      end

      it "returns primary model as effective_model_name again" do
        expect(config.effective_model_name).to eq("abs-claude-sonnet-4-6")
      end
    end

    context "when in :fallback_active (not probing yet)" do
      before do
        config.activate_fallback!("abs-claude-sonnet-4-5")
        config.confirm_fallback_ok!  # should be no-op
      end

      it "stays in fallback_active" do
        expect(config.fallback_active?).to be true
      end
    end

    context "when in :primary_ok" do
      it "is a no-op" do
        config.confirm_fallback_ok!
        expect(config.fallback_active?).to be false
      end
    end
  end

  # ── activate_fallback! renews timestamp (idempotent) ──────────────────────

  describe "renewing cooling-off via activate_fallback!" do
    it "resets the clock when called again" do
      config.activate_fallback!("abs-claude-sonnet-4-5")
      # Pretend it was activated 35 min ago (cooling-off expired)
      config.instance_variable_set(:@fallback_since, Time.now - 35 * 60)

      # Calling activate_fallback! again renews the timestamp
      config.activate_fallback!("abs-claude-sonnet-4-5")
      ts = config.instance_variable_get(:@fallback_since)
      expect(ts).to be_within(2).of(Time.now)

      # Cooling-off should NOT have expired yet
      config.maybe_start_probing
      expect(config.probing?).to be false
    end
  end

  # ── fallback_model_for ─────────────────────────────────────────────────────

  describe "#fallback_model_for" do
    it "returns the configured fallback for the primary model" do
      result = config.fallback_model_for("abs-claude-sonnet-4-6")
      expect(result).to eq("abs-claude-sonnet-4-5")
    end

    it "returns nil for a model with no fallback configured" do
      result = config.fallback_model_for("abs-claude-haiku-4")
      expect(result).to be_nil
    end
  end
end
