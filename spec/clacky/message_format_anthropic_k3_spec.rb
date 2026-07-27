# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::MessageFormat::Anthropic, "Kimi K3 thinking format" do
  let(:messages) { [{ role: "user", content: "hi" }] }
  let(:tools) { [] }
  let(:max_tokens) { 1024 }

  context "when model is kimi-k3" do
    it "uses thinking:{type:'enabled'} instead of adaptive" do
      body = described_class.build_request_body(messages, "kimi-k3", tools, max_tokens, false, reasoning_effort: "high")
      expect(body[:thinking]).to eq({ type: "enabled" })
    end

    it "maps 'max' effort to output_config:{effort:'max'}" do
      body = described_class.build_request_body(messages, "kimi-k3", tools, max_tokens, false, reasoning_effort: "max")
      expect(body[:thinking]).to eq({ type: "enabled" })
      expect(body[:output_config]).to eq({ effort: "max" })
    end

    it "maps 'xhigh' effort to output_config:{effort:'max'}" do
      body = described_class.build_request_body(messages, "kimi-k3", tools, max_tokens, false, reasoning_effort: "xhigh")
      expect(body[:thinking]).to eq({ type: "enabled" })
      expect(body[:output_config]).to eq({ effort: "max" })
    end

    it "passes through 'high' effort unchanged" do
      body = described_class.build_request_body(messages, "kimi-k3", tools, max_tokens, false, reasoning_effort: "high")
      expect(body[:thinking]).to eq({ type: "enabled" })
      expect(body[:output_config]).to eq({ effort: "high" })
    end

    it "passes through 'medium' effort unchanged" do
      body = described_class.build_request_body(messages, "kimi-k3", tools, max_tokens, false, reasoning_effort: "medium")
      expect(body[:thinking]).to eq({ type: "enabled" })
      expect(body[:output_config]).to eq({ effort: "medium" })
    end

    it "passes through 'low' effort unchanged" do
      body = described_class.build_request_body(messages, "kimi-k3", tools, max_tokens, false, reasoning_effort: "low")
      expect(body[:thinking]).to eq({ type: "enabled" })
      expect(body[:output_config]).to eq({ effort: "low" })
    end

    it "does not emit output_config when reasoning_effort is nil" do
      body = described_class.build_request_body(messages, "kimi-k3", tools, max_tokens, false, reasoning_effort: nil)
      expect(body[:thinking]).to eq({ type: "enabled" })
      expect(body).not_to have_key(:output_config)
    end

    it "does not emit output_config when reasoning_effort is 'on'" do
      body = described_class.build_request_body(messages, "kimi-k3", tools, max_tokens, false, reasoning_effort: "on")
      expect(body[:thinking]).to eq({ type: "enabled" })
      expect(body).not_to have_key(:output_config)
    end

    it "does not emit output_config for unknown efforts" do
      body = described_class.build_request_body(messages, "kimi-k3", tools, max_tokens, false, reasoning_effort: "unknown")
      expect(body[:thinking]).to eq({ type: "enabled" })
      expect(body).not_to have_key(:output_config)
    end
  end

  context "when model is k3 (bare alias)" do
    it "matches the K3 branch" do
      body = described_class.build_request_body(messages, "k3", tools, max_tokens, false, reasoning_effort: "max")
      expect(body[:thinking]).to eq({ type: "enabled" })
      expect(body[:output_config]).to eq({ effort: "max" })
    end
  end

  context "when model is claude-sonnet-4 (non-K3)" do
    it "still uses adaptive thinking for non-K3 models" do
      body = described_class.build_request_body(messages, "claude-sonnet-4", tools, max_tokens, false, reasoning_effort: "high")
      expect(body[:thinking]).to eq({ type: "adaptive" })
      expect(body[:output_config]).to eq({ effort: "high" })
    end

    it "does not emit thinking when reasoning_effort is nil" do
      body = described_class.build_request_body(messages, "claude-sonnet-4", tools, max_tokens, false, reasoning_effort: nil)
      expect(body).not_to have_key(:thinking)
      expect(body).not_to have_key(:output_config)
    end
  end

  context "when model is kimi-k2.5 (non-K3 kimi model)" do
    it "still uses adaptive thinking (not fixed by this patch)" do
      body = described_class.build_request_body(messages, "kimi-k2.5", tools, max_tokens, false, reasoning_effort: "high")
      expect(body[:thinking]).to eq({ type: "adaptive" })
      expect(body[:output_config]).to eq({ effort: "high" })
    end
  end
end
