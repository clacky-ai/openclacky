# frozen_string_literal: true

require "spec_helper"
require "clacky/agent"

# Runtime tests for the tool-loop detector (issue #440).
#
# We use Clacky::Agent.allocate (which skips #initialize) so we can exercise
# the private signature, window and state-machine logic directly, without
# mocking the whole dependency chain (LLM client, UI controller, tool
# registry, session store). This mirrors the approach in
# degraded_iteration_spec.rb.
#
# These tests guard the invariants a source-level scan cannot verify:
#   1. Signature canonicalization (key type/order/JSON-string insensitivity).
#   2. The sliding-window repetition counter and streak state-machine
#      (notice → warning → critical → break, reset on a fresh turn).
#   3. Warning/break injection into the message history.

RSpec.describe Clacky::Agent do
  let(:agent) { Clacky::Agent.allocate }

  before do
    agent.instance_variable_set(:@recent_tool_signatures, [])
    agent.instance_variable_set(:@unresolved_loop_streak, 0)
    agent.instance_variable_set(:@iterations, 0)
    allow(Clacky::Logger).to receive(:warn)
  end

  def sig(name, args)
    agent.send(:tool_call_signature, { name: name, arguments: args })
  end

  def detect(*calls)
    agent.send(:detect_tool_calls_loop, calls)
  end

  def streak
    agent.instance_variable_get(:@unresolved_loop_streak)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Signature canonicalization: #tool_call_signature
  # ═══════════════════════════════════════════════════════════════════════════
  describe "#tool_call_signature" do
    it "is insensitive to symbol vs string keys" do
      expect(sig("file_reader", { path: "a.rb", start_line: 1 }))
        .to eq(sig("file_reader", { "path" => "a.rb", "start_line" => 1 }))
    end

    it "is insensitive to key order" do
      expect(sig("file_reader", { path: "a.rb", line: 1 }))
        .to eq(sig("file_reader", { line: 1, path: "a.rb" }))
    end

    it "treats a JSON string argument the same as the equivalent Hash" do
      expect(sig("file_reader", '{"path":"a.rb"}'))
        .to eq(sig("file_reader", { path: "a.rb" }))
    end

    it "ignores JSON whitespace differences" do
      expect(sig("file_reader", '{ "path" : "a.rb" }'))
        .to eq(sig("file_reader", '{"path":"a.rb"}'))
    end

    it "distinguishes different arguments" do
      expect(sig("file_reader", { path: "a.rb" }))
        .not_to eq(sig("file_reader", { path: "b.rb" }))
    end

    it "distinguishes different tool names" do
      expect(sig("file_reader", { path: "a.rb" }))
        .not_to eq(sig("terminal", { path: "a.rb" }))
    end

    it "handles nil arguments without raising" do
      expect { sig("terminal", nil) }.not_to raise_error
    end

    it "handles non-JSON string arguments gracefully" do
      expect { sig("terminal", "not json") }.not_to raise_error
      expect(sig("terminal", "not json")).to eq("terminal:not json")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Repetition state machine: #detect_tool_calls_loop
  # ═══════════════════════════════════════════════════════════════════════════
  describe "#detect_tool_calls_loop" do
    let(:read_a) { { name: "file_reader", arguments: { path: "a.rb" } } }
    let(:read_b) { { name: "file_reader", arguments: { path: "b.rb" } } }

    it "returns nil and keeps a zero streak for a fresh turn" do
      expect(detect(read_a)).to be_nil
      expect(streak).to eq(0)
    end

    it "escalates notice → warning → critical → break across consecutive repeats" do
      detect(read_a) # turn 1: fresh
      expect(detect(read_a)).to eq(:notice)   # turn 2
      expect(detect(read_a)).to eq(:warning)  # turn 3
      expect(detect(read_a)).to eq(:critical) # turn 4
      expect(detect(read_a)).to eq(:break)    # turn 5
      expect(streak).to eq(4)
    end

    it "resets the streak when a turn introduces only new calls" do
      detect(read_a)            # fresh
      detect(read_a)            # notice (streak 1)
      expect(detect(read_b)).to be_nil # read_b is new → reset
      expect(streak).to eq(0)
      expect(detect(read_a)).to eq(:notice) # starts a fresh streak
    end

    it "keeps execution unblocked: a legitimate git status → edit → git status does not break" do
      git_status = { name: "terminal", arguments: { command: "git status" } }
      edit = { name: "edit", arguments: { path: "f.rb", old: "a", new: "b" } }

      expect(detect(git_status)).to be_nil   # fresh
      expect(detect(edit)).to be_nil         # edit is new → reset streak
      signal = detect(git_status)            # git status repeats, but only the first repeat
      expect(signal).to eq(:notice)          # a single nudge, not a break
      expect(streak).to eq(1)
    end

    it "detects a periodic multi-call cycle (the ABCD pattern from #440)" do
      a = { name: "file_reader", arguments: { path: "open_ai.rb", start_line: 260, end_line: 354 } }
      b = { name: "file_reader", arguments: { path: "open_ai.rb", start_line: 50, end_line: 80 } }
      c = { name: "terminal", arguments: { command: "grep foo llm_caller.rb" } }
      d = { name: "file_reader", arguments: { path: "llm_caller.rb", start_line: 100, end_line: 220 } }

      # Turn 1 — the initial cycle: all fresh.
      expect(detect(a, b, c, d)).to be_nil
      # Turn 2 — the cycle repeats verbatim.
      expect(detect(a, b, c, d)).to eq(:notice)
      expect(detect(a, b, c, d)).to eq(:warning)
      expect(detect(a, b, c, d)).to eq(:critical)
      expect(detect(a, b, c, d)).to eq(:break)
    end

    it "trims the window to LOOP_WINDOW_SIZE" do
      stub_const("Clacky::Agent::ToolLoopDetector::LOOP_WINDOW_SIZE", 3)
      calls = (1..5).map { |i| { name: "file_reader", arguments: { path: "f#{i}.rb" } } }
      calls.each { |c| detect(c) } # 5 distinct calls, no repetition
      window = agent.instance_variable_get(:@recent_tool_signatures)
      expect(window.size).to eq(3) # trimmed to the last 3
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Warning injection: #inject_tool_loop_warning
  # ═══════════════════════════════════════════════════════════════════════════
  describe "#inject_tool_loop_warning" do
    let(:history) { [] }
    let(:fake_history) { double("MessageHistory") }

    before do
      allow(fake_history).to receive(:append) { |msg| history << msg }
      agent.instance_variable_set(:@history, fake_history)
    end

    %i[notice warning critical].each do |level|
      it "appends a system-injected user message for #{level}" do
        agent.send(:inject_tool_loop_warning, level)
        expect(history.size).to eq(1)
        expect(history.first[:role]).to eq("user")
        expect(history.first[:system_injected]).to be true
        expect(history.first[:content]).to be_a(String)
        expect(history.first[:content]).not_to be_empty
      end
    end

    it "does nothing for an unknown level" do
      agent.send(:inject_tool_loop_warning, :nope)
      expect(history).to be_empty
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Force break: #handle_tool_loop_break
  # ═══════════════════════════════════════════════════════════════════════════
  describe "#handle_tool_loop_break" do
    let(:history) { [] }
    let(:fake_history) { double("MessageHistory") }
    let(:fake_ui) { double("UI") }

    before do
      allow(fake_history).to receive(:append) { |msg| history << msg }
      allow(fake_ui).to receive(:show_warning)
      agent.instance_variable_set(:@history, fake_history)
      agent.instance_variable_set(:@ui, fake_ui)
    end

    it "warns the user via the UI and appends a final system message" do
      agent.send(:handle_tool_loop_break)
      expect(fake_ui).to have_received(:show_warning).once
      expect(history.size).to eq(1)
      expect(history.first[:role]).to eq("user")
      expect(history.first[:system_injected]).to be true
    end
  end
end
