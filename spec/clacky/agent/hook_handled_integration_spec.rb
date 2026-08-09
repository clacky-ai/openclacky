# frozen_string_literal: true

require "spec_helper"

RSpec.describe "before_tool_use :handled short-circuits execution" do
  let(:client) { instance_double(Clacky::Client) }
  let(:config) { Clacky::AgentConfig.new }

  let(:agent) do
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.pwd, ui: nil, profile: "coding",
      session_id: Clacky::SessionManager.generate_id, source: :manual
    )
  end

  let(:hooks) { agent.instance_variable_get(:@hooks) }
  let(:tool_call) { { id: "call_1", name: "glob", arguments: { "pattern" => "*.rb" } } }

  def act(calls)
    agent.send(:act, calls)[:tool_results]
  end

  it "returns the hook's result without running the tool" do
    tool = agent.instance_variable_get(:@tool_registry).get("glob")
    allow(tool).to receive(:execute).and_call_original
    hooks.add(:before_tool_use) { { action: :handled, result: "handled by extension" } }

    results = act([tool_call])

    expect(tool).not_to have_received(:execute)
    expect(results.first[:content].to_s).to include("handled by extension")
  end

  it "still runs the tool when no hook handles the call" do
    executed = false
    hooks.add(:before_tool_use) { executed = true and nil }

    act([tool_call])

    expect(executed).to be(true)
  end

  it "produces a tool result bound to the original tool_call_id" do
    hooks.add(:before_tool_use) { { action: :handled, result: "x" } }

    results = act([tool_call])

    expect(results.first[:id]).to eq("call_1")
  end
end
