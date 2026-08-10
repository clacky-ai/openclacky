# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Agent::CostTracker, "#absorb_subagent_cost" do
  let(:agent) do
    Class.new do
      include Clacky::Agent::CostTracker

      attr_reader :total_cost, :sessionbar_updates

      def initialize
        @total_cost = 0.0
        @cost_mutex = Mutex.new
        @cost_source = :price
        @sessionbar_updates = []
        @ui = self
      end

      def update_sessionbar(cost:, cost_source:)
        @sessionbar_updates << { cost: cost, cost_source: cost_source }
      end
    end.new
  end

  it "adds the subagent spend to the running total" do
    agent.absorb_subagent_cost({ total_cost_usd: 0.25 })

    expect(agent.total_cost).to be_within(1e-9).of(0.25)
  end

  it "returns the absorbed amount" do
    expect(agent.absorb_subagent_cost({ total_cost_usd: 0.25 })).to eq(0.25)
  end

  it "treats a missing cost as free rather than raising" do
    expect { agent.absorb_subagent_cost({ iterations: 3 }) }.not_to raise_error
    expect(agent.total_cost).to eq(0.0)
  end

  it "tolerates a nil result" do
    expect { agent.absorb_subagent_cost(nil) }.not_to raise_error
    expect(agent.total_cost).to eq(0.0)
  end

  it "refreshes the sessionbar by default" do
    agent.absorb_subagent_cost({ total_cost_usd: 0.25 })

    expect(agent.sessionbar_updates).to eq([{ cost: 0.25, cost_source: :price }])
  end

  it "stays silent when the caller runs detached" do
    agent.absorb_subagent_cost({ total_cost_usd: 0.25 }, notify_ui: false)

    expect(agent.sessionbar_updates).to be_empty
    expect(agent.total_cost).to be_within(1e-9).of(0.25)
  end

  # A bare `+=` is rarely preempted under MRI's GVL, so a throughput test would
  # pass even unlocked. Pin the mutex contract directly instead.
  it "performs the read-modify-write under the cost mutex" do
    mutex = agent.instance_variable_get(:@cost_mutex)

    expect(mutex).to receive(:synchronize).once.and_call_original

    agent.absorb_subagent_cost({ total_cost_usd: 0.25 }, notify_ui: false)

    expect(agent.total_cost).to be_within(1e-9).of(0.25)
  end

  it "blocks a second absorber while one is mid-update" do
    mutex = agent.instance_variable_get(:@cost_mutex)
    blocked = nil

    mutex.lock
    other = Thread.new do
      agent.absorb_subagent_cost({ total_cost_usd: 0.25 }, notify_ui: false)
    end
    sleep 0.05
    blocked = other.status == "sleep" && agent.total_cost.zero?
    mutex.unlock
    other.join

    expect(blocked).to be(true)
    expect(agent.total_cost).to be_within(1e-9).of(0.25)
  end
end
