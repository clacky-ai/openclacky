# frozen_string_literal: true

require "spec_helper"
require "clacky/agent/goal_manager"

RSpec.describe Clacky::GoalManager do
  # A controllable stand-in for Clacky::Client: returns queued raw judge
  # responses (or raises) in order, recording the calls it received.
  let(:fake_client) do
    Class.new do
      attr_reader :calls

      def initialize
        @queue = []
        @calls = []
      end

      def queue
        @queue
      end

      def send_messages(messages, model:, max_tokens:)
        @calls << { messages: messages, model: model, max_tokens: max_tokens }
        item = @queue.shift
        raise item if item.is_a?(Class) && item < StandardError
        raise item if item.is_a?(StandardError)
        item
      end
    end.new
  end

  let(:manager) { described_class.new(judge_client: fake_client, judge_model: "judge-mini") }

  def queue_judge(raw)
    fake_client.queue << raw
  end

  describe "lifecycle" do
    it "starts with no goal" do
      expect(manager.has_goal?).to be_falsey
      expect(manager.active?).to be false
      expect(manager.to_h).to be_nil
    end

    it "set creates an active state" do
      state = manager.set("build the app", max_turns: 5)
      expect(state.goal).to eq("build the app")
      expect(state.max_turns).to eq(5)
      expect(manager.active?).to be true
      expect(manager.has_goal?).to be true
    end

    it "set strips surrounding whitespace" do
      expect(manager.set("  g  ").goal).to eq("g")
    end

    it "set rejects empty goal text" do
      expect { manager.set("   ") }.to raise_error(ArgumentError)
      expect { manager.set("") }.to raise_error(ArgumentError)
    end

    it "pause / resume / clear transition the state" do
      manager.set("g")
      manager.pause(reason: "user-paused")
      expect(manager.active?).to be false
      expect(manager.state.paused?).to be true
      expect(manager.state.paused_reason).to eq("user-paused")

      manager.resume
      expect(manager.active?).to be true
      expect(manager.state.paused_reason).to be_nil

      manager.clear
      expect(manager.has_goal?).to be_falsey
      expect(manager.to_h).to be_nil
    end

    it "resume resets turns_used by default" do
      manager.set("g", max_turns: 5)
      manager.state.turns_used = 4
      manager.pause
      manager.resume
      expect(manager.state.turns_used).to eq(0)
    end

    it "resume can keep the budget" do
      manager.set("g", max_turns: 5)
      manager.state.turns_used = 4
      manager.pause
      manager.resume(reset_budget: false)
      expect(manager.state.turns_used).to eq(4)
    end

    it "pause/resume/clear are no-ops without a state" do
      expect(manager.pause).to be_nil
      expect(manager.resume).to be_nil
      expect { manager.clear }.not_to raise_error
    end
  end

  describe "#status_line" do
    it "reports no goal" do
      expect(manager.status_line).to include("No active goal")
    end

    it "reports an active goal with turn budget" do
      manager.set("write specs", max_turns: 10)
      manager.state.turns_used = 3
      expect(manager.status_line).to include("active")
      expect(manager.status_line).to include("3/10 turns")
      expect(manager.status_line).to include("write specs")
    end

    it "reports a paused goal with reason" do
      manager.set("g")
      manager.pause(reason: "budget blown")
      expect(manager.status_line).to include("paused")
      expect(manager.status_line).to include("budget blown")
    end

    it "reports a done goal" do
      manager.set("g")
      manager.state.status = "done"
      expect(manager.status_line).to include("done")
    end
  end

  describe "#evaluate_after_turn" do
    it "returns an inactive decision when no goal is set" do
      d = manager.evaluate_after_turn("anything")
      expect(d[:should_continue]).to be false
      expect(d[:verdict]).to eq("inactive")
      expect(d[:continuation_prompt]).to be_nil
    end

    it "returns an inactive decision when the goal is paused" do
      manager.set("g")
      manager.pause
      d = manager.evaluate_after_turn("text")
      expect(d[:should_continue]).to be false
      expect(d[:verdict]).to eq("inactive")
      expect(d[:status]).to eq("paused")
    end

    it "increments turns_used and continues when the judge says continue" do
      manager.set("g", max_turns: 5)
      queue_judge('{"verdict":"continue","reason":"not yet"}')
      d = manager.evaluate_after_turn("working on it")

      expect(d[:should_continue]).to be true
      expect(d[:verdict]).to eq("continue")
      expect(d[:status]).to eq("active")
      expect(d[:continuation_prompt]).to include("Goal: g")
      expect(manager.state.turns_used).to eq(1)
      expect(manager.state.last_verdict).to eq("continue")
    end

    it "stops and marks done when the judge says done" do
      manager.set("g", max_turns: 5)
      queue_judge('{"verdict":"done","reason":"all green"}')
      d = manager.evaluate_after_turn("finished everything")

      expect(d[:should_continue]).to be false
      expect(d[:status]).to eq("done")
      expect(d[:verdict]).to eq("done")
      expect(d[:message]).to include("Goal achieved")
      expect(manager.state.done?).to be true
    end

    it "pauses when the turn budget is exhausted" do
      manager.set("g", max_turns: 2)
      # First turn: continue, budget still ok.
      queue_judge('{"verdict":"continue","reason":"keep going"}')
      manager.evaluate_after_turn("turn 1")
      # Second turn: would exhaust budget (turns_used 2 >= max 2).
      queue_judge('{"verdict":"continue","reason":"keep going"}')
      d = manager.evaluate_after_turn("turn 2")

      expect(d[:should_continue]).to be false
      expect(d[:status]).to eq("paused")
      expect(d[:reason]).to include("turn budget exhausted")
      expect(manager.state.paused?).to be true
    end

    it "keeps going (within budget) on a single unparseable judge reply" do
      manager.set("g", max_turns: 5)
      queue_judge("this is not json at all")
      d = manager.evaluate_after_turn("turn 1")

      expect(d[:should_continue]).to be true
      expect(d[:verdict]).to eq("continue")
      expect(manager.state.turns_used).to eq(1)
    end

    it "auto-pauses after MAX_CONSECUTIVE_JUDGE_FAILURES bad replies" do
      manager.set("g", max_turns: 10)
      limit = described_class::MAX_CONSECUTIVE_JUDGE_FAILURES

      (limit - 1).times do
        queue_judge("garbage")
        d = manager.evaluate_after_turn("turn")
        expect(d[:should_continue]).to be true
      end

      queue_judge("garbage")
      d = manager.evaluate_after_turn("turn")
      expect(d[:should_continue]).to be false
      expect(d[:status]).to eq("paused")
      expect(manager.state.paused?).to be true
    end

    it "resets the consecutive-failure counter after a successful judge call" do
      manager.set("g", max_turns: 10)
      limit = described_class::MAX_CONSECUTIVE_JUDGE_FAILURES

      (limit - 1).times { queue_judge("garbage"); manager.evaluate_after_turn("t") }
      # A good reply resets the counter.
      queue_judge('{"verdict":"continue","reason":"ok"}')
      manager.evaluate_after_turn("t")

      # Now we need another full run of failures before auto-pause.
      (limit - 1).times { queue_judge("garbage"); manager.evaluate_after_turn("t") }
      queue_judge("garbage")
      d = manager.evaluate_after_turn("t")
      expect(d[:status]).to eq("paused")
    end

    it "treats an empty agent response as a transient blip and continues" do
      manager.set("g", max_turns: 5)
      d = manager.evaluate_after_turn("")
      expect(d[:should_continue]).to be true
      expect(d[:reason]).to include("empty response")
      expect(manager.state.turns_used).to eq(1)
    end

    it "is fail-open when the judge client raises" do
      manager.set("g", max_turns: 10)
      fake_client.queue << RuntimeError.new("network down")
      d = manager.evaluate_after_turn("turn 1")
      expect(d[:should_continue]).to be true
      expect(manager.state.last_verdict).to be_nil
    end

    it "sends the judge system prompt and user prompt to the client" do
      manager.set("my goal", max_turns: 5)
      queue_judge('{"verdict":"continue","reason":"ok"}')
      manager.evaluate_after_turn("agent reply text")

      call = fake_client.calls.first
      expect(call[:model]).to eq("judge-mini")
      expect(call[:max_tokens]).to eq(described_class::JUDGE_MAX_TOKENS)
      system_content = call[:messages].find { |m| m[:role] == "system" }[:content]
      user_content = call[:messages].find { |m| m[:role] == "user" }[:content]
      expect(system_content).to include("strict judge")
      expect(user_content).to include("my goal")
      expect(user_content).to include("agent reply text")
    end
  end

  describe "judge reply parsing" do
    it "accepts bare JSON" do
      manager.set("g", max_turns: 5)
      queue_judge('{"verdict":"done","reason":"yep"}')
      d = manager.evaluate_after_turn("text")
      expect(d[:verdict]).to eq("done")
    end

    it "strips markdown code fences" do
      manager.set("g", max_turns: 5)
      queue_judge("```json\n{\"verdict\":\"continue\",\"reason\":\"x\"}\n```")
      d = manager.evaluate_after_turn("text")
      expect(d[:verdict]).to eq("continue")
    end

    it "extracts JSON embedded in prose" do
      manager.set("g", max_turns: 5)
      queue_judge('Sure! {"verdict":"done","reason":"done"} there.')
      d = manager.evaluate_after_turn("text")
      expect(d[:verdict]).to eq("done")
    end

    it "defaults an unknown verdict to continue" do
      manager.set("g", max_turns: 5)
      queue_judge('{"verdict":"maybe","reason":"unsure"}')
      d = manager.evaluate_after_turn("text")
      expect(d[:verdict]).to eq("continue")
    end

    it "treats a missing reason as a placeholder" do
      manager.set("g", max_turns: 5)
      queue_judge('{"verdict":"done"}')
      manager.evaluate_after_turn("text")
      expect(manager.state.last_reason).to eq("no reason provided")
    end
  end

  describe "#to_h" do
    it "delegates to the state" do
      manager.set("g", max_turns: 3)
      h = manager.to_h
      expect(h[:goal]).to eq("g")
      expect(h[:max_turns]).to eq(3)
    end
  end
end
