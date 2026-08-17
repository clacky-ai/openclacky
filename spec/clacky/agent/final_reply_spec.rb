# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Agent, "#final_reply" do
  let(:client) { instance_double(Clacky::Client) }
  let(:config) { Clacky::AgentConfig.new }

  let(:agent) do
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.pwd, ui: nil, profile: "coding",
      session_id: Clacky::SessionManager.generate_id, source: :manual
    )
  end

  def subagent_with(messages, parent_count:)
    history = instance_double(Clacky::MessageHistory, to_a: messages)
    instance_double(Clacky::Agent, history: history).tap do |sub|
      allow(sub).to receive(:instance_variable_get)
        .with(:@parent_message_count).and_return(parent_count)
    end
  end

  it "returns the last non-empty assistant message" do
    sub = subagent_with([
      { role: "assistant", content: "early" },
      { role: "assistant", content: "final answer" }
    ], parent_count: 0)

    expect(agent.final_reply(sub)).to eq("final answer")
  end

  # A subagent's history usually ends with tool results, not its answer, so the
  # scan has to walk backwards past them.
  it "skips trailing tool results to find the answer" do
    sub = subagent_with([
      { role: "assistant", content: "the answer" },
      { role: "tool", content: "tool output" }
    ], parent_count: 0)

    expect(agent.final_reply(sub)).to eq("the answer")
  end

  it "ignores the inherited parent conversation" do
    sub = subagent_with([
      { role: "assistant", content: "parent turn" },
      { role: "assistant", content: "subagent turn" }
    ], parent_count: 1)

    expect(agent.final_reply(sub)).to eq("subagent turn")
  end

  it "returns an empty string when the subagent never answered" do
    sub = subagent_with([{ role: "tool", content: "only tool output" }], parent_count: 0)

    expect(agent.final_reply(sub)).to eq("")
  end

  it "treats an empty assistant message as no answer" do
    sub = subagent_with([
      { role: "assistant", content: "real answer" },
      { role: "assistant", content: "" }
    ], parent_count: 0)

    expect(agent.final_reply(sub)).to eq("real answer")
  end

  it "survives a subagent that appended nothing after the fork" do
    sub = subagent_with([{ role: "assistant", content: "parent only" }], parent_count: 5)

    expect(agent.final_reply(sub)).to eq("")
  end
end
