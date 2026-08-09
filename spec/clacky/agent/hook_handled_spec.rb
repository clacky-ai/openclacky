# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::HookManager, "handled action" do
  let(:manager) { described_class.new }
  let(:call) { { id: "call_1", name: "invoke_skill", arguments: { "skill_name" => "demo" } } }

  it "reports the handled verdict with its result" do
    manager.add(:before_tool_use) { { action: :handled, result: "done by hook" } }

    verdict = manager.trigger(:before_tool_use, call)

    expect(verdict[:action]).to eq(:handled)
    expect(verdict[:result]).to eq("done by hook")
  end

  it "stops the chain once a hook handles the call" do
    later_ran = false
    manager.add(:before_tool_use) { { action: :handled, result: "first" } }
    manager.add(:before_tool_use) { later_ran = true }

    verdict = manager.trigger(:before_tool_use, call)

    expect(verdict[:result]).to eq("first")
    expect(later_ran).to be(false)
  end

  it "lets an earlier deny win over a later handled" do
    manager.add(:before_tool_use) { { action: :deny, reason: "blocked" } }
    manager.add(:before_tool_use) { { action: :handled, result: "should not reach" } }

    verdict = manager.trigger(:before_tool_use, call)

    expect(verdict[:action]).to eq(:deny)
    expect(verdict[:reason]).to eq("blocked")
  end

  it "lets an earlier handled win over a later deny" do
    manager.add(:before_tool_use) { { action: :handled, result: "fanned out" } }
    manager.add(:before_tool_use) { { action: :deny, reason: "too late" } }

    verdict = manager.trigger(:before_tool_use, call)

    expect(verdict[:action]).to eq(:handled)
  end

  it "still allows when no hook handles the call" do
    manager.add(:before_tool_use) { nil }

    expect(manager.trigger(:before_tool_use, call)).to eq({ action: :allow })
  end

  it "skips a raising hook and lets a later one handle the call" do
    manager.add(:before_tool_use) { raise "hook exploded" }
    manager.add(:before_tool_use) { { action: :handled, result: "recovered" } }

    allow(Clacky::Logger).to receive(:error)

    verdict = manager.trigger(:before_tool_use, call)

    expect(verdict[:action]).to eq(:handled)
    expect(verdict[:result]).to eq("recovered")
  end
end
