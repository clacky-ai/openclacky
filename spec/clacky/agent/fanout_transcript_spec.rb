# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Agent, "fan-out transcript persistence" do
  let(:client) { instance_double(Clacky::Client) }
  let(:config) { Clacky::AgentConfig.new }

  let(:agent) do
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.pwd, ui: nil, profile: "coding",
      session_id: Clacky::SessionManager.generate_id, source: :manual
    )
  end

  # A stand-in for a forked subagent: fan_out_labeled only reads its history,
  # iterations and cost, so a real fork (network + config deep copy) is overkill.
  def fake_subagent(messages, iterations: 2, cost: 0.01)
    sub = Object.new
    sub.instance_variable_set(:@parent_message_count, 0)
    sub.define_singleton_method(:history) { Clacky::MessageHistory.new(messages) }
    sub.define_singleton_method(:iterations) { iterations }
    sub.define_singleton_method(:total_cost) { cost }
    sub
  end

  def tool_result_message(tool_call_id)
    { role: "tool", tool_call_id: tool_call_id, content: "done" }
  end

  describe "#fan_out_labeled with :subagent" do
    it "orders transcripts by job index regardless of completion order" do
      jobs = [
        { label: "slow", run: -> { sleep 0.1 }, subagent: fake_subagent([{ role: "assistant", content: "A" }]) },
        { label: "fast", run: -> {},            subagent: fake_subagent([{ role: "assistant", content: "B" }]) }
      ]

      agent.fan_out_labeled(jobs, max_concurrency: 2, tool_call_id: "call_1")
      agent.history.append(tool_result_message("call_1"))
      agent.send(:attach_pending_subagent_transcripts, { tool_calls: [{ id: "call_1" }] })

      expect(agent.history.to_a.last[:subagent_transcript].map { |t| t[:skill] }).to eq(%w[slow fast])
    end

    it "attaches the batch to the matching tool result message" do
      jobs = [
        { label: "alpha", run: -> {}, subagent: fake_subagent([{ role: "assistant", content: "A" }]) },
        { label: "beta",  run: -> {}, subagent: fake_subagent([{ role: "assistant", content: "B" }]) }
      ]

      agent.fan_out_labeled(jobs, max_concurrency: 2, tool_call_id: "call_1")
      agent.history.append(tool_result_message("call_1"))
      agent.send(:attach_pending_subagent_transcripts, { tool_calls: [{ id: "call_1" }] })

      batch = agent.history.to_a.last[:subagent_transcript]
      expect(batch.map { |t| t[:skill] }).to eq(%w[alpha beta])
      expect(batch.map { |t| t[:index] }).to eq([0, 1])
    end

    it "records a trail for a job that raised" do
      jobs = [
        { label: "boom", run: -> { raise "nope" }, subagent: fake_subagent([{ role: "assistant", content: "tried" }]) }
      ]

      results = agent.fan_out_labeled(jobs, tool_call_id: "call_1")
      agent.history.append(tool_result_message("call_1"))
      agent.send(:attach_pending_subagent_transcripts, { tool_calls: [{ id: "call_1" }] })

      expect(results.first).not_to be_ok
      expect(agent.history.to_a.last[:subagent_transcript].first[:skill]).to eq("boom")
    end

    it "collects nothing when the caller passes no tool_call_id" do
      agent.fan_out_labeled([{ label: "a", run: -> {}, subagent: fake_subagent([]) }])

      expect(agent.instance_variable_get(:@pending_subagent_transcripts)).to be_empty
    end

    it "collects nothing when a job omits :subagent" do
      agent.fan_out_labeled([{ label: "a", run: -> {} }], tool_call_id: "call_1")

      expect(agent.instance_variable_get(:@pending_subagent_transcripts)).to be_empty
    end

    it "keeps concurrent batches from cross-attaching" do
      agent.fan_out_labeled(
        [{ label: "a", run: -> {}, subagent: fake_subagent([{ role: "assistant", content: "A" }]) }],
        tool_call_id: "call_1"
      )
      agent.fan_out_labeled(
        [{ label: "b", run: -> {}, subagent: fake_subagent([{ role: "assistant", content: "B" }]) }],
        tool_call_id: "call_2"
      )

      agent.history.append(tool_result_message("call_1"))
      agent.history.append(tool_result_message("call_2"))
      agent.send(:attach_pending_subagent_transcripts, { tool_calls: [{ id: "call_1" }, { id: "call_2" }] })

      msgs = agent.history.to_a
      expect(msgs[-2][:subagent_transcript].map { |t| t[:skill] }).to eq(%w[a])
      expect(msgs[-1][:subagent_transcript].map { |t| t[:skill] }).to eq(%w[b])
    end

    it "consumes the buffer so a transcript attaches exactly once" do
      agent.fan_out_labeled(
        [{ label: "a", run: -> {}, subagent: fake_subagent([{ role: "assistant", content: "A" }]) }],
        tool_call_id: "call_1"
      )
      agent.history.append(tool_result_message("call_1"))
      agent.send(:attach_pending_subagent_transcripts, { tool_calls: [{ id: "call_1" }] })
      agent.send(:attach_pending_subagent_transcripts, { tool_calls: [{ id: "call_1" }] })

      expect(agent.instance_variable_get(:@pending_subagent_transcripts)).to be_empty
    end
  end

  describe "LLM payload isolation" do
    it "strips subagent transcripts before sending to the API" do
      agent.fan_out_labeled(
        [{ label: "a", run: -> {}, subagent: fake_subagent([{ role: "assistant", content: "secret trail" }]) }],
        tool_call_id: "call_1"
      )
      agent.history.append(tool_result_message("call_1"))
      agent.send(:attach_pending_subagent_transcripts, { tool_calls: [{ id: "call_1" }] })

      api_msg = agent.history.to_api.last

      expect(agent.history.to_a.last).to have_key(:subagent_transcript)
      expect(api_msg).not_to have_key(:subagent_transcript)
    end
  end

  describe "transcript size cap" do
    it "drops the oldest events and leaves a marker when over the event cap" do
      over = Clacky::Agent::MAX_TRANSCRIPT_EVENTS + 50
      messages = Array.new(over) { |i| { role: "assistant", content: "step #{i}" } }

      transcript = agent.extract_subagent_transcript(fake_subagent(messages), "big")
      events = transcript[:events]

      expect(events.size).to be <= Clacky::Agent::MAX_TRANSCRIPT_EVENTS + 1
      expect(events.first[:content]).to match(/earlier event\(s\) omitted/)
      expect(events.last[:content]).to eq("step #{over - 1}")
    end

    it "caps total bytes so one chatty subagent cannot bloat session.json" do
      fat = "x" * 10_000
      messages = Array.new(40) { { role: "assistant", content: fat } }

      transcript = agent.extract_subagent_transcript(fake_subagent(messages), "fat")
      bytes = transcript[:events].sum { |e| e[:content].to_s.bytesize }

      expect(bytes).to be <= Clacky::Agent::MAX_TRANSCRIPT_BYTES + 1_000
    end

    it "leaves a small transcript untouched" do
      messages = [{ role: "assistant", content: "hi" }, { role: "tool", content: "ok", tool_call_id: "t1" }]

      transcript = agent.extract_subagent_transcript(fake_subagent(messages), "small")

      expect(transcript[:events].map { |e| e[:content] }).to eq(%w[hi ok])
    end
  end

  # An interrupted fan-out never reaches observe(), so the captured trails sit
  # in @pending_subagent_transcripts (memory only). The interrupt path must
  # settle the dangling tool_calls turn by appending a synthetic tool result
  # carrying the trails, so they survive a reload.
  describe "flushing pending transcripts on interrupt" do
    it "settles the dangling tool_calls turn with a tool result carrying the trails" do
      agent.fan_out_labeled(
        [
          { label: "slow", run: -> {}, subagent: fake_subagent([{ role: "assistant", content: "A" }]) },
          { label: "fast", run: -> {}, subagent: fake_subagent([{ role: "assistant", content: "B" }]) }
        ],
        tool_call_id: "call_1"
      )
      # Simulate the assistant turn that requested the fan-out; its tool result
      # was never written because the batch was cancelled first.
      agent.history.append({ role: "assistant", content: nil,
                             tool_calls: [{ id: "call_1", name: "task" }] })

      agent.send(:flush_pending_subagent_transcripts_on_interrupt)

      last = agent.history.to_a.last
      expect(last[:role]).to eq("tool")
      expect(last[:tool_call_id]).to eq("call_1")
      expect(last[:subagent_transcript].map { |t| t[:skill] }).to eq(%w[slow fast])
    end

    it "survives the drop_dangling_tool_calls that runs before a follow-up user message" do
      agent.fan_out_labeled(
        [{ label: "a", run: -> {}, subagent: fake_subagent([{ role: "assistant", content: "A" }]) }],
        tool_call_id: "call_1"
      )
      agent.history.append({ role: "assistant", content: nil, tool_calls: [{ id: "call_1", name: "task" }] })

      agent.send(:flush_pending_subagent_transcripts_on_interrupt)
      agent.history.append({ role: "user", content: "follow up" })

      trail = agent.history.to_a.find { |m| m[:subagent_transcript] }
      expect(trail[:subagent_transcript].map { |t| t[:skill] }).to eq(%w[a])
    end

    it "drains the buffer so a later attach does not double-anchor" do
      agent.fan_out_labeled(
        [{ label: "a", run: -> {}, subagent: fake_subagent([{ role: "assistant", content: "A" }]) }],
        tool_call_id: "call_1"
      )
      agent.history.append({ role: "assistant", content: nil, tool_calls: [{ id: "call_1", name: "task" }] })

      agent.send(:flush_pending_subagent_transcripts_on_interrupt)
      agent.history.append(tool_result_message("call_2"))
      agent.send(:attach_pending_subagent_transcripts, { tool_calls: [{ id: "call_2" }] })

      expect(agent.history.to_a.last).not_to have_key(:subagent_transcript)
    end

    it "is a no-op when there is nothing pending" do
      expect { agent.send(:flush_pending_subagent_transcripts_on_interrupt) }.not_to raise_error
    end
  end

  describe "#replay_one_subagent_transcript phase wrapping" do
    def collect(transcript)
      events = []
      ui = Clacky::Server::HistoryCollector.new("sess-1", events)
      agent.send(:replay_one_subagent_transcript, transcript, ui)
      events
    end

    let(:transcript) do
      {
        skill: "Design 1/2",
        iterations: 3,
        cost_usd: 0.02,
        events: [
          { role: "assistant", content: "looking", tool_calls: [{ name: "glob", arguments: { "pattern" => "**/*.rb" } }] },
          { role: "tool", content: "match.rb" }
        ]
      }
    end

    it "brackets the transcript with phase_start / phase_end" do
      events = collect(transcript)
      expect(events.first[:type]).to eq("phase_start")
      expect(events.last[:type]).to eq("phase_end")
      expect(events.first[:kind]).to eq("fanout_subagent")
      expect(events.first[:label]).to eq("Design 1/2")
    end

    it "stamps the same phase_id onto every subagent event in between" do
      events = collect(transcript)
      pid = events.first[:phase_id]
      expect(pid).not_to be_nil

      inner = events[1..-2]
      expect(inner.map { |e| e[:type] }).to eq(%w[subagent_start assistant_message tool_call tool_result subagent_end])
      expect(inner.map { |e| e[:phase_id] }.uniq).to eq([pid])
      expect(events.last[:phase_id]).to eq(pid)
    end

    it "clears the phase id so later events are not stamped" do
      events = []
      ui = Clacky::Server::HistoryCollector.new("sess-1", events)
      agent.send(:replay_one_subagent_transcript, transcript, ui)
      ui.show_assistant_message("outer", files: [])
      expect(events.last[:type]).to eq("assistant_message")
      expect(events.last).not_to have_key(:phase_id)
    end
  end
end
