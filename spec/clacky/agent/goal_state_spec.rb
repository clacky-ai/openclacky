# frozen_string_literal: true

require "spec_helper"
require "clacky/agent/goal_state"

RSpec.describe Clacky::GoalState do
  describe "#initialize" do
    it "defaults status to active and turns_used to 0" do
      s = described_class.new(goal: "write tests")
      expect(s.goal).to eq("write tests")
      expect(s.status).to eq("active")
      expect(s.turns_used).to eq(0)
      expect(s.max_turns).to eq(Clacky::GoalState::DEFAULT_MAX_TURNS)
      expect(s.active?).to be true
      expect(s.paused?).to be false
      expect(s.done?).to be false
      expect(s.budget_exhausted?).to be false
    end

    it "coerces goal to string" do
      expect(described_class.new(goal: 42).goal).to eq("42")
    end

    it "accepts a custom max_turns" do
      s = described_class.new(goal: "g", max_turns: 5)
      expect(s.max_turns).to eq(5)
    end

    it "falls back to default max_turns when given a non-positive value" do
      expect(described_class.new(goal: "g", max_turns: 0).max_turns).to eq(Clacky::GoalState::DEFAULT_MAX_TURNS)
      expect(described_class.new(goal: "g", max_turns: -3).max_turns).to eq(Clacky::GoalState::DEFAULT_MAX_TURNS)
    end

    it "normalizes an unknown status to active" do
      expect(described_class.new(goal: "g", status: "bogus").status).to eq("active")
    end

    it "keeps known statuses" do
      expect(described_class.new(goal: "g", status: "paused").status).to eq("paused")
      expect(described_class.new(goal: "g", status: :done).status).to eq("done")
    end

    it "coerces turns_used to integer" do
      expect(described_class.new(goal: "g", turns_used: "7").turns_used).to eq(7)
    end

    it "sets created_at automatically" do
      expect(described_class.new(goal: "g").created_at).to be_a(Float)
    end
  end

  describe "#budget_exhausted?" do
    it "is true once turns_used reaches max_turns" do
      s = described_class.new(goal: "g", max_turns: 3, turns_used: 2)
      expect(s.budget_exhausted?).to be false
      s.turns_used = 3
      expect(s.budget_exhausted?).to be true
    end
  end

  describe "predicates" do
    it "reflect the current status" do
      s = described_class.new(goal: "g")
      expect(s.active?).to be true
      s.status = "paused"
      expect(s.paused?).to be true
      expect(s.active?).to be false
      s.status = "done"
      expect(s.done?).to be true
    end
  end

  describe "#to_h / .from_h round trip" do
    it "preserves all fields with symbol keys" do
      original = described_class.new(
        goal: "ship the feature",
        max_turns: 7,
        turns_used: 3,
        last_verdict: "continue",
        last_reason: "still going",
        paused_reason: nil,
        created_at: 1_700_000_000.0,
        last_turn_at: 1_700_000_005.0
      )

      h = original.to_h
      expect(h).to be_a(Hash)
      expect(h.keys).to all(be_a(Symbol))

      restored = described_class.from_h(h)
      expect(restored.goal).to eq("ship the feature")
      expect(restored.status).to eq("active")
      expect(restored.max_turns).to eq(7)
      expect(restored.turns_used).to eq(3)
      expect(restored.last_verdict).to eq("continue")
      expect(restored.last_reason).to eq("still going")
      expect(restored.created_at).to eq(1_700_000_000.0)
      expect(restored.last_turn_at).to eq(1_700_000_005.0)
    end
  end

  describe ".from_h" do
    it "tolerates string keys (session.json round-trip)" do
      h = { "goal" => "g", "status" => "paused", "turns_used" => 4, "max_turns" => 10 }
      s = described_class.from_h(h)
      expect(s.goal).to eq("g")
      expect(s.status).to eq("paused")
      expect(s.turns_used).to eq(4)
      expect(s.max_turns).to eq(10)
    end

    it "returns nil for nil / non-hash / empty goal" do
      expect(described_class.from_h(nil)).to be_nil
      expect(described_class.from_h("string")).to be_nil
      expect(described_class.from_h({})).to be_nil
      expect(described_class.from_h(goal: "   ")).to be_nil
    end

    it "defaults missing optional fields" do
      s = described_class.from_h(goal: "g")
      expect(s.status).to eq("active")
      expect(s.turns_used).to eq(0)
      expect(s.max_turns).to eq(Clacky::GoalState::DEFAULT_MAX_TURNS)
    end
  end
end
