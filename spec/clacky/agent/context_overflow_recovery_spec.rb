# frozen_string_literal: true

require "spec_helper"
require "clacky/agent/llm_caller"

# Tests for the two-layer context-overflow recovery in
# Clacky::Agent::LlmCaller#perform_context_overflow_compression.
#
# Strategy: build a minimal host class that exposes the private method,
# fakes out @history / compress_messages_if_needed / call_llm /
# handle_compression_response. We assert:
#   - mode: :standard uses pull_back_from_tail: 1 (cache-preserving)
#   - mode: :aggressive uses pull_back_from_tail ≈ history_size / 2
#   - aggressive always pulls back at least 4 (small histories)
#   - aggressive never exceeds history_size - 2 (safety floor)
#   - aggressive caps at 64 (worst-case bound)
#   - on Layer 1 failure, the rescue block re-runs in :aggressive mode
RSpec.describe "Clacky::Agent::LlmCaller context-overflow recovery" do
  # Minimal host: just enough to drive perform_context_overflow_compression.
  let(:host_class) do
    Class.new do
      include Clacky::Agent::LlmCaller
      public :perform_context_overflow_compression

      attr_accessor :history_size, :compress_calls, :call_llm_results,
                    :compress_results

      def initialize
        @history_size = 0
        @compress_calls = []
        @call_llm_results = []   # array of values OR exceptions to raise in order
        @compress_results = []   # array of return values for compress_messages_if_needed
        @history_appends = []
        # The production code reads @history.size / @history.append etc.
        # Build a stub up-front and store it in the instance variable so it
        # behaves identically to a real Agent's @history.
        host = self
        @history = Object.new.tap do |h|
          h.define_singleton_method(:size) { host.history_size }
          h.define_singleton_method(:append) { |msg| host.instance_variable_get(:@history_appends) << msg }
          h.define_singleton_method(:rollback_before) { |_msg| nil }
        end
      end

      def compress_messages_if_needed(force:, pull_back_from_tail:)
        @compress_calls << { force: force, pull_back_from_tail: pull_back_from_tail }
        result = @compress_results.shift
        result.is_a?(Exception) ? (raise result) : result
      end

      def call_llm
        nxt = @call_llm_results.shift
        nxt.is_a?(Exception) ? (raise nxt) : nxt
      end

      def handle_compression_response(_response, _context); end
    end
  end

  let(:host) do
    h = host_class.new
    h.history_size = 50
    h
  end

  let(:fake_compression_context) do
    {
      compression_message: { role: "user", content: "compress" },
      pulled_back_messages: []
    }
  end

  describe "#perform_context_overflow_compression(mode: :standard)" do
    it "calls compress_messages_if_needed with pull_back_from_tail: 1" do
      host.compress_results = [fake_compression_context]
      host.call_llm_results = [{ content: "ok" }]

      result = host.perform_context_overflow_compression(mode: :standard)

      expect(result).to be true
      expect(host.compress_calls).to eq([{ force: true, pull_back_from_tail: 1 }])
    end

    it "returns false (and does not raise) when the inner call_llm fails" do
      host.compress_results = [fake_compression_context]
      host.call_llm_results = [Clacky::BadRequestError.new("ctx too long")]

      result = host.perform_context_overflow_compression(mode: :standard)

      expect(result).to be false
    end

    it "returns false when compression itself is skipped (returns nil)" do
      host.compress_results = [nil]

      expect(host.perform_context_overflow_compression(mode: :standard)).to be false
      # No second call_llm should have been attempted.
      expect(host.call_llm_results).to be_empty
    end
  end

  describe "#perform_context_overflow_compression(mode: :aggressive)" do
    it "pulls back about half the history" do
      host.history_size = 50
      host.compress_results = [fake_compression_context]
      host.call_llm_results = [{ content: "ok" }]

      host.perform_context_overflow_compression(mode: :aggressive)

      expect(host.compress_calls.first[:pull_back_from_tail]).to eq(25)
    end

    it "enforces a minimum pull-back of 4 even on small histories" do
      host.history_size = 6   # half = 3, but min should be 4
      host.compress_results = [fake_compression_context]
      host.call_llm_results = [{ content: "ok" }]

      host.perform_context_overflow_compression(mode: :aggressive)

      expect(host.compress_calls.first[:pull_back_from_tail]).to eq(4)
    end

    it "never pops more than (history_size - 2)" do
      # Tiny history: half=2, min=4, but cap at history_size-2 = 3
      host.history_size = 5
      host.compress_results = [fake_compression_context]
      host.call_llm_results = [{ content: "ok" }]

      host.perform_context_overflow_compression(mode: :aggressive)

      expect(host.compress_calls.first[:pull_back_from_tail]).to eq(3)
    end

    it "caps pull-back at 64 for absurdly large histories" do
      host.history_size = 500   # half = 250, but cap at 64
      host.compress_results = [fake_compression_context]
      host.call_llm_results = [{ content: "ok" }]

      host.perform_context_overflow_compression(mode: :aggressive)

      expect(host.compress_calls.first[:pull_back_from_tail]).to eq(64)
    end
  end

  describe "two-layer escalation pattern" do
    # Simulates the rescue-block flow: Layer 1 fails (call_llm overflows
    # again), then caller invokes Layer 2, which uses a much larger pull-back.
    it "Layer 1 with pull_back: 1 fails, then Layer 2 with pull_back: ~half succeeds" do
      host.history_size = 40

      # First: Layer 1 — compression returns valid context, call_llm fails.
      # Second: Layer 2 — compression returns valid context, call_llm succeeds.
      host.compress_results = [fake_compression_context, fake_compression_context]
      host.call_llm_results = [
        Clacky::BadRequestError.new("Range of input length should be [1, 229376]"),
        { content: "ok" }
      ]

      r1 = host.perform_context_overflow_compression(mode: :standard)
      r2 = host.perform_context_overflow_compression(mode: :aggressive)

      expect(r1).to be false
      expect(r2).to be true

      # Verify pull-back values used in each layer.
      expect(host.compress_calls.map { |c| c[:pull_back_from_tail] }).to eq([1, 20])
    end
  end
end
