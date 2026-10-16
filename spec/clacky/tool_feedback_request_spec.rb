# frozen_string_literal: true
require "spec_helper"
require "tmpdir"
require "clacky/server/http_server"

RSpec.describe "Business tool feedback requests" do
  around { |example| Dir.mktmpdir { |dir| @directory = dir; example.run } }

  def run_feedback(mode:, intervene: false)
    config = Clacky::AgentConfig.new(permission_mode: mode)
    config.ask_user_timeout_seconds = 0
    @events = []
    ui = nil
    ui = Clacky::Server::WebUIController.new("business-feedback", lambda do |_id, event|
      @events << event
      ui.intervene_feedback(event[:request_id]) if intervene && event[:type] == "feedback_countdown" && event[:deadline_ms]
    end)
    client = Clacky::Client.new("test", base_url: "https://unused.invalid", model: "test")
    @agent = Clacky::Agent.new(client, config, working_dir: @directory, ui: ui, profile: "coding",
                               session_id: "business-feedback", source: :web)
    allow(@agent).to receive(:confirm_tool_use?).and_return(true)
    @agent.add_hook(:after_tool_use) do |_call, result|
      result[:feedback_request] = { question: "Use the new version?", options: ["New", "Old"],
                                    context: '{"type":"custom.version","id":"v1"}',
                                    auto_reply: "Use the new version and continue." }
    end
    call = { id: "write-version", name: "write", arguments: JSON.generate(path: "version.html", content: "new") }
    @agent.history.append(role: "assistant", content: "", tool_calls: @agent.send(:format_tool_calls_for_api, [call]))
    result = @agent.send(:act, [call])
    @agent.send(:observe, { content: "", tool_calls: [call] }, result[:tool_results])
    expect(@events.none? { |event| event[:type] == "request_feedback" }).to be(true)
    @agent.history.append(role: "assistant", content: "Validation complete")
    result[:feedback_outcome] = @agent.send(:settle_tool_feedback)
    result
  end

  [[:auto_approve, false, 3], [:auto_approve, true, 2], [:confirm_all, false, 2]].each do |mode, intervene, calls|
    it "settles the choice after validation in a real agent run (#{mode}, takeover=#{intervene})" do
      config = Clacky::AgentConfig.new(permission_mode: mode, memory_update_enabled: false, skill_evolution: { enabled: false })
      config.add_model(model: "claude-sonnet-4.5", api_key: "test", base_url: "https://unused.invalid")
      config.ask_user_timeout_seconds = 0
      client = Clacky::Client.new("test", base_url: "https://unused.invalid", model: "test")
      events = []
      ui = nil
      ui = Clacky::Server::WebUIController.new("run-feedback", lambda do |_id, event|
        events << event
        ui.intervene_feedback(event[:request_id]) if intervene && event[:type] == "feedback_countdown" && event[:deadline_ms]
      end)
      agent = Clacky::Agent.new(client, config, working_dir: @directory, ui: ui, profile: "coding", session_id: "run-feedback", source: :web)
      allow(agent).to receive(:confirm_tool_use?).and_return(true)
      agent.add_hook(:after_tool_use) do |_call, result|
        result[:feedback_request] = { question: "Use this?", options: ["New", "Old"], auto_reply: "Choose New and continue." }
      end
      allow(client).to receive(:send_messages_with_tools).and_return(
        mock_api_response(content: nil, tool_calls: [mock_tool_call(name: "write", args: JSON.generate(path: "new.html", content: "new"))]),
        mock_api_response(content: "Validation complete"),
        mock_api_response(content: "Continued"))
      allow(agent).to receive(:run_skill_evolution_hooks)
      allow(agent).to receive(:run_memory_update_subagent)
      result = agent.run("Make a design")
      expect(result[:awaiting_user_feedback]).to eq(calls == 2)
      expect(client).to have_received(:send_messages_with_tools).exactly(calls).times
      before = events.index { |event| event[:type] == "assistant_message" && event[:content] == "Validation complete" }
      waiting = events.index { |event| event[:type] == "request_feedback" }
      expect(before).to be < waiting
      expect(agent.history.to_a.count { |message| message[:role].to_s == "user" && !message[:system_injected] }).to eq(1)
    end
  end

  it "waits manually without losing the business result" do
    result = run_feedback(mode: :confirm_all)
    expect(result[:feedback_outcome]).to eq(:waiting)
    expect(JSON.parse(result[:tool_results].first[:content])).to include("bytes_written" => 3)
    expect(@events).to include(hash_including(type: "request_feedback", question: "Use the new version?"))
  end

  it "uses the native timeout and preserves the automatic continuation instruction" do
    result = run_feedback(mode: :auto_approve)
    expect(result[:feedback_outcome]).to eq(:continue)
    expect(@agent.history.to_a.last).to include(system_injected: true, content: "Use the new version and continue.")
    expect(@events).to include(hash_including(type: "feedback_countdown", resolution: :timeout))
  end

  it "hands control back on intervention" do
    result = run_feedback(mode: :auto_approve, intervene: true)
    expect(result[:feedback_outcome]).to eq(:waiting)
    expect(JSON.parse(result[:tool_results].first[:content])).not_to have_key("auto_reply")
  end

  it "replays the timeout outcome without fabricating a user answer" do
    run_feedback(mode: :auto_approve)
    events = []
    @agent.replay_history(Clacky::Server::HistoryCollector.new("business-feedback", events), limit: 30)
    expect(events).to include(hash_including(type: "feedback_countdown", resolved: true, resolution: :timeout))
    expect(events.none? { |event| event[:type] == "history_user_message" }).to be(true)
  end

  it "restores the business feedback descriptor through history replay" do
    run_feedback(mode: :confirm_all)
    events = []
    @agent.replay_history(Clacky::Server::HistoryCollector.new("business-feedback", events), limit: 30)
    expect(events).to include(hash_including(type: "request_feedback", context: '{"type":"custom.version","id":"v1"}'))
  end
end
