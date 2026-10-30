# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe "Business tool feedback" do
  let(:directory) { Dir.mktmpdir("tool-feedback") }
  let(:events) { [] }
  let(:config) { Clacky::AgentConfig.new(permission_mode: :confirm_all, ask_user_timeout_seconds: 0) }
  let(:client) { Clacky::Client.new("test", base_url: "https://unused.invalid", model: "test") }
  let(:ui) { Clacky::Server::WebUIController.new("tool-feedback", ->(_id, event) { events << event }) }
  let(:agent) { Clacky::Agent.new(client, config, working_dir: directory, ui: ui, profile: "coding", session_id: "tool-feedback", source: :web) }
  let(:terminal) { agent.instance_variable_get(:@tool_registry).get("terminal") }
  let(:call) { { id: "business-1", name: "terminal", arguments: JSON.generate(command: "true") } }
  let(:request) do
    { question: "Pick a design", options: ["A: /a.html", "B: /b.html"],
      context: "Both designs are complete.", metadata: { eazo: { kind: "design", id: "business-1" } } }
  end

  before do
    agent.history.append(role: "user", content: "Create an app")
    agent.history.append(role: "assistant", content: "", tool_calls: [
      { id: call[:id], type: "function", function: { name: call[:name], arguments: call[:arguments] } }
    ]) { |message| @assistant_message = message }
    allow(terminal).to receive(:execute).and_return(exit_code: 0, output: "Saved", feedback_request: request)
    allow(client).to receive(:send_messages_with_tools).and_raise("Unexpected network request")
    # Extensions own business association receipts; core only persists/replays them.
    agent.add_hook(:after_tool_use) do |executed, result|
      source = result.dig(:feedback_request, :metadata, :eazo)
      next unless source && !result[:error] && result[:success] != false

      agent.emit_event("ext.example.feedback_requested", request_id: executed[:id],
                       feedback_source: source, persist: true)
    end
  end

  after { FileUtils.remove_entry(directory) }

  def execute(calls = [call])
    agent.send(:act, calls, assistant_message: @assistant_message)
  end

  def payload(action)
    JSON.parse(action[:tool_results].first[:content], symbolize_names: true)
  end

  def replay(instance = agent)
    output = []
    instance.replay_history(Clacky::Server::HistoryCollector.new("tool-feedback", output), limit: 30)
    output
  end

  it "uses the existing preparation hook, snapshot and UI for a business result" do
    prepared_count = 0
    agent.add_hook(:prepare_feedback) do |prepared|
      prepared_count += 1
      prepared[:questions] << { question: "Next step?", options: ["Build", "Discuss"] }
      prepared[:answer_context] = "Discuss means no file changes."
    end
    action = execute
    result = payload(action)
    event = events.find { |entry| entry[:type] == "request_feedback" }
    expect(event).to include(request_id: call[:id])
    expect(event[:questions].first[:metadata]).to eq(request[:metadata])
    expect(event[:questions].size).to eq(2)
    expect(event.to_s).not_to include("Discuss means")
    expect(result[:message]).to include("Pick a design", "Next step?", "Discuss means no file changes.")
    expect(result[:feedback_request][:questions]).to eq(event[:questions])
    expect(result[:feedback_request]).not_to have_key(:answer_context)
    expect(action[:awaiting_feedback]).to be true
    expect(prepared_count).to eq(1)
    expect(events.count { |entry| entry[:type] == "request_feedback" }).to eq(1)
    expect(@assistant_message[:tool_calls].first[:function][:name]).to eq("terminal")
    expect(@assistant_message[:tool_calls].first[:function][:arguments]).to eq(call[:arguments])
  end

  [:confirm_all, :auto_approve].each do |mode|
    it "preserves main's execution of remaining tools in #{mode}" do
      config.permission_mode = mode
      expect(terminal).to receive(:execute).twice.and_return(
        { exit_code: 0, feedback_request: request },
        { exit_code: 0, output: "Sibling completed" }
      )
      action = execute([call, call.merge(id: "sibling")])
      expect(action[:tool_results].size).to eq(2)
      expect(JSON.parse(action[:tool_results].last[:content])).to include("output" => "Sibling completed")
      expect(action[:awaiting_feedback]).to eq(mode == :confirm_all)
      expect(payload(action).key?(:auto_reply)).to eq(mode == :auto_approve)
    end
  end

  it "times out without a browser and preserves the outcome after restoring the session" do
    config.permission_mode = :auto_approve
    action = execute
    expect(payload(action)[:auto_reply]).to include("reasonable decision")
    expect(events).to include(hash_including(type: "feedback_countdown", request_id: call[:id], resolution: :timeout))
    agent.send(:observe, { tool_calls: [call] }, action[:tool_results])
    restored = Clacky::Agent.new(client, config, working_dir: directory, ui: ui,
                                profile: "coding", session_id: "tool-feedback", source: :web)
    restored.restore_session(JSON.parse(JSON.generate(agent.to_session_data), symbolize_names: true))
    output = replay(restored)
    expect(output.none? { |event| event[:type] == "request_feedback" }).to be true
    expect(output.count { |event| event[:type] == "ext.example.feedback_requested" }).to eq(1)
    expect(output.find { |event| event[:type] == "ext.example.feedback_requested" }).to include(
      request_id: call[:id], feedback_source: request[:metadata][:eazo])
    restored_result = JSON.parse(output.find { |event| event[:type] == "tool_result" }[:result], symbolize_names: true)
    expect(restored_result).to include(auto_reply: /reasonable decision/)
    expect(restored_result[:feedback_request][:request_id]).to eq(call[:id])
    expect(output.none? { |event| event[:type] == "feedback_countdown" }).to be true
    expect(output.index { |event| event[:type] == "tool_result" }).to be > output.index { |event| event[:type] == "ext.example.feedback_requested" }
    expect(agent.history.to_api.first).not_to have_key(:feedback_requests)
  end

  it "does not reconstruct a business request from its tool result" do
    action = execute
    output = []
    collector = Clacky::Server::HistoryCollector.new("tool-feedback", output)
    agent.send(:emit_replayed_tool_result, collector, action[:tool_results].first[:content], call[:id])
    expect(output.map { |event| event[:type] }).to eq(["tool_result"])
  end

  it "restores waiting from history before observation and reuses main's live deadline" do
    config.permission_mode = :auto_approve
    config.ask_user_timeout_seconds = 20
    started = Queue.new
    allow(ui).to receive(:emit).and_wrap_original do |original, type, **data|
      original.call(type, **data)
      started << data if type == "feedback_countdown" && data[:deadline_ms]
    end
    worker = Thread.new { execute }
    deadline = started.pop[:deadline_ms]
    output = replay
    expect(output.count { |event| event[:type] == "ext.example.feedback_requested" }).to eq(1)
    expect(output.none? { |event| event[:type] == "request_feedback" || event[:type] == "tool_result" }).to be true
    ui.replay_live_state
    expect(events.last).to include(type: "feedback_countdown", request_id: call[:id], deadline_ms: deadline)
  ensure
    ui.intervene_feedback(call[:id])
    worker&.join(2)
    worker&.kill if worker&.alive?
  end

  it "continues the model loop with the full business result after Auto times out" do
    config.permission_mode = :auto_approve
    allow(agent).to receive(:think).and_return(
      { content: nil, tool_calls: [call], history_message: @assistant_message },
      { content: "I chose B and continued.", tool_calls: [] }
    )
    outcome = agent.run("Continue with a design")
    expect(outcome[:status]).to eq(:success)
    expect(agent).to have_received(:think).twice
    tool_result = agent.history.to_a.find { |message| message[:role].to_s == "tool" }
    result = JSON.parse(tool_result[:content], symbolize_names: true)
    expect(result).to include(output: "Saved", auto_reply: /reasonable decision/)
    expect(result[:feedback_request][:questions].first[:options]).to eq(request[:options])
  end

  [:intervened, "Use B"].each do |answer|
    it "respects human takeover during Auto: #{answer}" do
      config.permission_mode = :auto_approve
      allow(ui).to receive(:request_feedback_with_countdown).and_return(answer)
      action = execute
      expect(payload(action)).not_to have_key(:auto_reply)
      expect(action[:awaiting_feedback]).to eq(answer == :intervened)
      expect(action[:feedback]).to eq(answer.is_a?(String) ? answer : nil)
      expect(payload(action)[:feedback_request][:questions].first[:options]).to eq(request[:options])
    end
  end

  it "replays a manual request without resolving it" do
    action = execute
    agent.send(:observe, { tool_calls: [call] }, action[:tool_results])
    output = replay
    expect(output.none? { |event| event[:type] == "request_feedback" }).to be true
    expect(output.find { |event| event[:type] == "ext.example.feedback_requested" }).to include(
      request_id: call[:id], feedback_source: request[:metadata][:eazo])
    expect(output.none? { |event| event[:resolved] }).to be true
    expect(output.index { |event| event[:type] == "tool_result" }).to be > output.index { |event| event[:type] == "ext.example.feedback_requested" }
  end

  it "preserves the App AI presentation and complete model list in model context" do
    models = [{ model_key: "model-a" }, { model_key: "model-b" }]
    event = { version: 1, id: call[:id], name: "app_ai.model_selection.requested",
              payload: { models: models }, created_at: "2026-10-23T00:00:00Z" }
    selection = request.merge(context: JSON.generate(models: models), metadata: { eazo: { kind: "app_ai", event: event } })
    allow(terminal).to receive(:execute).and_return(exit_code: 0, feedback_request: selection)
    result = payload(execute)
    expect(result[:message]).to include("model-a", "model-b")
    expect(events.find { |entry| entry[:type] == "request_feedback" }[:questions].first[:metadata]).to eq(selection[:metadata])
  end

  [ { error: "failed" }, { success: false } ].each do |failure|
    it "rejects feedback on a failed result #{failure}" do
      allow(terminal).to receive(:execute).and_return({ exit_code: 0, feedback_request: request }.merge(failure))
      expect(execute[:awaiting_feedback]).to be false
      expect(events.none? { |event| event[:type] == "request_feedback" }).to be true
    end
  end
end
