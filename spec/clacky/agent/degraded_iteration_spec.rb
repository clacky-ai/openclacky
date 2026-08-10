# frozen_string_literal: true

require "spec_helper"
require "clacky/agent"

# Runtime tests for the degraded-iteration detector (PR #417).
#
# We use Clacky::Agent.allocate (which skips #initialize) so we can exercise
# the private predicate and counter logic directly, without mocking the entire
# dependency chain (LLM client, UI controller, tool registry, session store).
# This mirrors the "minimal host" approach used by llm_caller_error_detection_spec.
#
# These tests guard the two invariants that a source-level scan cannot verify:
#   1. The *numerical* judgement of #degraded_break? (thresholds, boundaries).
#   2. The counter state-machine in #process_degraded_break (accumulate / warn
#      / reset), including the length-truncation exclusion and question exemption.

RSpec.describe Clacky::Agent do
  let(:agent) { Clacky::Agent.allocate }

  # ═══════════════════════════════════════════════════════════════════════════
  # Pure predicate: #degraded_break?
  # ═══════════════════════════════════════════════════════════════════════════
  describe "#degraded_break?" do
    def call(content, tokens, ends_q, finish_reason)
      agent.send(:degraded_break?, content, tokens, ends_q, finish_reason)
    end

    context "with normal healthy output" do
      it "returns false for long low-ratio output" do
        expect(call("x" * 500, 200, false, "stop")).to be false
      end

      it "returns false at the exact tokens=100 boundary (strictly >100 required)" do
        expect(call("x" * 200, 100, false, "stop")).to be false
      end
    end

    context "token-burn pattern (high token/char ratio)" do
      it "returns true when burning many tokens for little output" do
        expect(call("x" * 100, 2568, false, "stop")).to be true # ratio ≈ 25.7
      end

      it "returns true at a ratio just above the threshold" do
        # tokens=151, len=100 → ratio=1.51 > 1.5
        expect(call("x" * 100, 151, false, "stop")).to be true
      end

      it "returns false at the exact ratio=1.5 boundary (strictly >1.5 required)" do
        # tokens=150, len=100 → ratio=1.5, not strictly greater
        expect(call("x" * 100, 150, false, "stop")).to be false
      end
    end

    context "stunted-output pattern (short non-question text)" do
      it "returns true for very short output" do
        expect(call("x" * 33, 39, false, "stop")).to be true
      end

      it "returns false at the exact len=60 boundary (strictly <60 required)" do
        expect(call("x" * 60, 50, false, "stop")).to be false
      end

      it "returns false for a short question (question exemption)" do
        expect(call("怎么处理？", 10, true, "stop")).to be false
      end
    end

    context "length-truncation exclusion" do
      it "returns false for a high-ratio turn truncated by max_tokens" do
        # The regression that the finish_reason gate prevents: a legitimate
        # long-code turn capped at max_tokens would otherwise be misclassified.
        expect(call("x" * 3000, 16384, false, "length")).to be false
      end

      it "returns false for a short turn truncated by length" do
        expect(call("x" * 33, 39, false, "length")).to be false
      end
    end

    context "edge cases" do
      it "handles empty content without raising (division-by-zero protection)" do
        expect { call("", 200, false, "stop") }.not_to raise_error
        expect(call("", 200, false, "stop")).to be true # len=0 < 60
      end

      it "handles nil finish_reason gracefully" do
        expect(call("x" * 500, 200, false, nil)).to be false
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Counter state machine: #process_degraded_break
  # ═══════════════════════════════════════════════════════════════════════════
  describe "#process_degraded_break" do
    before do
      allow(Clacky::Logger).to receive(:warn)
      @fake_ui = double("UI")
      allow(@fake_ui).to receive(:show_warning)
      agent.instance_variable_set(:@ui, @fake_ui)
      agent.instance_variable_set(:@degraded_break_count, 0)
    end

    def process(content, tokens, ends_q, finish_reason)
      agent.send(:process_degraded_break, content, tokens, ends_q, finish_reason)
    end

    def count
      agent.instance_variable_get(:@degraded_break_count)
    end

    # degraded: short non-question text  → trips the stunted-output pattern
    let(:degraded) { ["x" * 33, 39, false, "stop"] }
    # healthy: long low-ratio output      → normal completion
    let(:healthy) { ["x" * 500, 200, false, "stop"] }

    it "increments the counter on a single degraded break without warning" do
      process(*degraded)
      expect(count).to eq(1)
      expect(@fake_ui).not_to have_received(:show_warning)
    end

    it "does not warn after two consecutive degraded breaks" do
      process(*degraded)
      process(*degraded)
      expect(count).to eq(2)
      expect(@fake_ui).not_to have_received(:show_warning)
    end

    it "warns and resets the counter after three consecutive degraded breaks" do
      process(*degraded)
      process(*degraded)
      process(*degraded)
      expect(count).to eq(0)
      expect(@fake_ui).to have_received(:show_warning).once
    end

    it "resets the counter when a healthy break interrupts the streak" do
      process(*degraded)
      process(*degraded)
      process(*healthy) # healthy break resets
      expect(count).to eq(0)
      process(*degraded) # starts fresh streak
      expect(count).to eq(1)
      expect(@fake_ui).not_to have_received(:show_warning)
    end

    it "never warns when degraded breaks are interleaved with healthy ones" do
      process(*degraded)
      process(*healthy)
      process(*degraded)
      process(*healthy)
      process(*degraded)
      expect(count).to eq(1) # never reaches 3 consecutive
      expect(@fake_ui).not_to have_received(:show_warning)
    end

    it "logs a warning via Clacky::Logger for each degraded break" do
      process(*degraded)
      expect(Clacky::Logger).to have_received(:warn).with(
        "agent.degraded_break_detected", hash_including(degraded_break_count: 1)
      )
    end
  end
end
