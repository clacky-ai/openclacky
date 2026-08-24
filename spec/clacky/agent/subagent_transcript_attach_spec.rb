# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Subagent transcript attachment (per tool_call_id)" do
  let(:client) { instance_double(Clacky::Client) }
  let(:config) { Clacky::AgentConfig.new }

  let(:agent) do
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.pwd, ui: nil, profile: "coding",
      session_id: Clacky::SessionManager.generate_id, source: :manual
    )
  end

  def pending_transcripts
    agent.instance_variable_get(:@pending_subagent_transcripts)
  end

  def attach(response)
    agent.send(:attach_pending_subagent_transcripts, response)
  end

  def tool_result_message(tool_call_id)
    { role: "tool", tool_call_id: tool_call_id, content: "done" }
  end

  # Stored as a batch: a lone subagent is just a batch of one.
  def transcript(skill)
    [{ skill: skill, iterations: 1, cost_usd: 0.0, index: 0, events: [{ role: "assistant", content: "hi" }] }]
  end

  def attached_skills(msg)
    Array(msg[:subagent_transcript]).map { |t| t[:skill] }
  end

  describe "with several invoke_skill calls in one turn" do
    let(:response) do
      {
        tool_calls: [
          { id: "call_a", name: "invoke_skill" },
          { id: "call_b", name: "invoke_skill" }
        ]
      }
    end

    before do
      agent.history.append(tool_result_message("call_a"))
      agent.history.append(tool_result_message("call_b"))
    end

    it "attaches each subagent trail to the call that spawned it" do
      pending_transcripts["call_a"] = transcript("explorer")
      pending_transcripts["call_b"] = transcript("pptx")

      attach(response)

      messages = agent.history.to_a
      msg_a = messages.find { |m| m[:tool_call_id] == "call_a" }
      msg_b = messages.find { |m| m[:tool_call_id] == "call_b" }

      expect(attached_skills(msg_a)).to eq(["explorer"])
      expect(attached_skills(msg_b)).to eq(["pptx"])
    end

    it "leaves the other call untouched when only one skill forked a subagent" do
      pending_transcripts["call_b"] = transcript("pptx")

      attach(response)

      messages = agent.history.to_a
      expect(messages.find { |m| m[:tool_call_id] == "call_a" }).not_to have_key(:subagent_transcript)
      expect(attached_skills(messages.find { |m| m[:tool_call_id] == "call_b" })).to eq(["pptx"])
    end

    it "consumes each transcript exactly once" do
      pending_transcripts["call_a"] = transcript("explorer")
      pending_transcripts["call_b"] = transcript("pptx")

      attach(response)

      expect(pending_transcripts).to be_empty
    end
  end

  it "attaches a single transcript to its own call" do
    agent.history.append(tool_result_message("call_solo"))
    pending_transcripts["call_solo"] = transcript("explorer")

    attach({ tool_calls: [{ id: "call_solo", name: "invoke_skill" }] })

    expect(attached_skills(agent.history.to_a.last)).to eq(["explorer"])
  end

  it "ignores non-invoke_skill calls sharing the turn" do
    agent.history.append(tool_result_message("call_read"))
    agent.history.append(tool_result_message("call_skill"))
    pending_transcripts["call_skill"] = transcript("explorer")

    attach({
             tool_calls: [
               { id: "call_read", name: "file_reader" },
               { id: "call_skill", name: "invoke_skill" }
             ]
           })

    messages = agent.history.to_a
    expect(messages.find { |m| m[:tool_call_id] == "call_read" }).not_to have_key(:subagent_transcript)
    expect(attached_skills(messages.find { |m| m[:tool_call_id] == "call_skill" })).to eq(["explorer"])
  end

  it "resolves the tool name from OpenAI-style nested function hashes" do
    agent.history.append(tool_result_message("call_nested"))
    pending_transcripts["call_nested"] = transcript("explorer")

    attach({ tool_calls: [{ id: "call_nested", function: { name: "invoke_skill" } }] })

    expect(attached_skills(agent.history.to_a.last)).to eq(["explorer"])
  end

  it "is a no-op when nothing is pending" do
    agent.history.append(tool_result_message("call_a"))

    expect { attach({ tool_calls: [{ id: "call_a", name: "invoke_skill" }] }) }
      .not_to(change { agent.history.to_a })
  end

  it "keeps a transcript pending when its call is absent from the response" do
    agent.history.append(tool_result_message("call_a"))
    pending_transcripts["call_ghost"] = transcript("explorer")

    attach({ tool_calls: [{ id: "call_a", name: "invoke_skill" }] })

    expect(pending_transcripts).to have_key("call_ghost")
  end

  describe "slash-command path" do
    it "records no transcript when there is no originating tool call" do
      skill = instance_double(Clacky::Skill, identifier: "explorer")
      allow(agent).to receive(:extract_subagent_transcript).and_return(transcript("explorer"))

      # Mirrors execute_skill_with_subagent's guard: no tool_call_id, nothing to attach to.
      agent.send(:attach_pending_subagent_transcripts, { tool_calls: [] })

      expect(pending_transcripts).to be_empty
      expect(skill.identifier).to eq("explorer")
    end
  end
end
