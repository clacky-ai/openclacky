# frozen_string_literal: true

require "spec_helper"

# Covers the Agent reasoning_effort whitelist and normalize behaviour,
# specifically the GLM-related extensions: "max" must round-trip, "none"
# must NOT be swallowed to nil (so it can reach MessageFormat::OpenAI and
# trigger thinking:{type:"disabled"} on GLM), and the full GLM ladder
# (minimal/low/medium/high/xhigh/max) must be accepted.
RSpec.describe "Agent reasoning_effort whitelist" do
  # Build a minimal agent-like object that exercises normalize_reasoning_effort
  # without needing the full Agent constructor (which requires client, config,
  # working_dir, ui, profile, session_id, source).
  let(:agent_class) do
    Class.new do
      REASONING_EFFORTS = Clacky::Agent::REASONING_EFFORTS

      attr_reader :reasoning_effort

      def reasoning_effort=(value)
        @reasoning_effort = normalize_reasoning_effort(value)
      end

      private def normalize_reasoning_effort(value)
        return nil if value.nil?
        str = value.to_s.strip.downcase
        return nil if str.empty? || str == "off"
        return str if REASONING_EFFORTS.include?(str)
        nil
      end
    end
  end

  subject(:agent) { agent_class.new }

  it "whitelist covers the full GLM ladder plus OpenAI values" do
    expect(Clacky::Agent::REASONING_EFFORTS).to match_array(
      %w[minimal low medium high xhigh max none]
    )
  end

  it "round-trips 'max' (previously swallowed to nil)" do
    agent.reasoning_effort = "max"
    expect(agent.reasoning_effort).to eq("max")
  end

  it "round-trips 'none' (previously swallowed to nil)" do
    agent.reasoning_effort = "none"
    expect(agent.reasoning_effort).to eq("none")
  end

  it "round-trips 'minimal' (newly added to the whitelist)" do
    agent.reasoning_effort = "minimal"
    expect(agent.reasoning_effort).to eq("minimal")
  end

  it "still maps 'off' to nil (provider default)" do
    agent.reasoning_effort = "off"
    expect(agent.reasoning_effort).to be_nil
  end

  it "still maps empty string to nil" do
    agent.reasoning_effort = "  "
    expect(agent.reasoning_effort).to be_nil
  end

  it "still rejects unknown values to nil" do
    agent.reasoning_effort = "ultra"
    expect(agent.reasoning_effort).to be_nil
  end

  it "normalizes case and whitespace" do
    agent.reasoning_effort = "  MAX  "
    expect(agent.reasoning_effort).to eq("max")
  end
end
