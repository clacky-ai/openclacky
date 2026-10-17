# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe "Prepared feedback" do
  let(:directory) { Dir.mktmpdir("prepared-feedback") }
  let(:events) { [] }
  let(:session_id) { Clacky::SessionManager.generate_id }
  let(:ui) { Clacky::Server::WebUIController.new(session_id, ->(_id, event) { events << event }) }
  let(:config) { Clacky::AgentConfig.new(permission_mode: :confirm_all, ask_user_timeout_seconds: 0) }
  let(:client) { Clacky::Client.new("test", base_url: "https://unused.invalid", model: "test") }
  let(:agent) do
    Clacky::Agent.new(client, config, working_dir: directory, ui: ui,
                     session_id: session_id, source: :web, profile: "coding")
  end
  let(:call) { { id: "ask-context", name: "ask_user", arguments: JSON.generate(question: "Audience?", options: ["Families"]) } }

  before do
    agent.history.append(role: "user", content: "Build a travel app", task_id: "task-1")
    agent.history.append(role: "assistant", content: "", task_id: "task-1", tool_calls: [
      { id: call[:id], type: "function", function: { name: call[:name], arguments: call[:arguments] } }
    ]) { |stored_message| @assistant_message = stored_message }
    allow(client).to receive(:send_messages).and_raise("Unexpected network request")
    allow(client).to receive(:send_messages_with_tools).and_raise("Unexpected network request")
  end

  after { FileUtils.remove_entry(directory) }

  def replay(instance = agent)
    output = []
    instance.replay_history(Clacky::Server::HistoryCollector.new(session_id, output), limit: 30)
    output.select { |event| event[:type] == "request_feedback" }
  end

  ["How should we continue?", "下一步怎么继续？"].each do |question|
    [:confirm_all, :auto_approve].each do |mode|
      it "shares #{question} across live UI, model result and restored history in #{mode}" do
        config.permission_mode = mode
        agent.add_hook(:prepare_feedback) do |request|
          expect(events.none? { |event| %w[request_feedback feedback_countdown].include?(event[:type]) }).to be(true)
          request[:questions] << { question: question, options: ["Explore", "Discuss"], recommended: 1,
                                   metadata: { source: "test.extension", turn_id: "turn-1" } }
          request[:answer_context] = "Discuss means no file changes."
        end
        action = agent.send(:act, [call], assistant_message: @assistant_message)
        result = JSON.parse(action[:tool_results].first[:content], symbolize_names: true)
        prepared = agent.history.to_a.find { |item| item[:feedback_requests] }.fetch(:feedback_requests).fetch(call[:id])
        expect(result).not_to have_key(:feedback_request)
        expect(result[:message]).to eq(Clacky::Tools::AskUser.render_text(prepared[:questions], prepared[:context]) + "\n\nDiscuss means no file changes.")
        event = events.find { |entry| entry[:type] == "request_feedback" }
        expect(event[:questions]).to eq(prepared[:questions])
        expect(event[:questions].last[:metadata]).to eq(source: "test.extension", turn_id: "turn-1")
        expect(event[:request_id]).to eq("ask-context")
        expect(event).not_to have_key(:answer_context)
        expect(event.to_s).not_to include("Discuss means no file changes.")
        expect(prepared[:questions].last[:question]).to eq(question)
        expect(action[:awaiting_feedback]).to eq(mode == :confirm_all)
        if mode == :auto_approve
          expect(result[:auto_reply]).to include("reasonable decision")
          expect(events.select { |entry| entry[:type] == "feedback_countdown" }.map { |entry| entry[:request_id] }.uniq).to eq(["ask-context"])
        end

        # A reconnect during the wait has no tool result yet.
        expect(replay.first[:questions]).to eq(prepared[:questions])
        expect(replay.first[:request_id]).to eq("ask-context")
        expect(agent.history.to_api.first).not_to have_key(:feedback_requests)
        expect(agent.history.to_api.to_s).not_to include("feedback_requests")
        original = agent.history.to_a.find { |item| item[:tool_calls] }
        expect(original[:tool_calls].first[:function][:arguments]).to eq(call[:arguments])

        agent.send(:observe, { tool_calls: [call] }, action[:tool_results])
        expect(agent.history.to_api.to_s).to include(question, "Explore", "Discuss")
        payload = JSON.parse(JSON.generate(agent.to_session_data), symbolize_names: true)
        restored = Clacky::Agent.new(client, config, working_dir: directory, ui: ui,
                                    session_id: session_id, source: :web, profile: "coding")
        restored.restore_session(payload)
        expect(replay(restored).first[:questions]).to eq(prepared[:questions])
        expect(replay(restored).first[:request_id]).to eq("ask-context")
        expect(replay(restored).to_s).not_to include("Discuss means no file changes.")
      end
    end
  end

  it "passes the stored message from thinking through the run loop" do
    allow(client).to receive(:send_messages_with_tools)
      .and_return(mock_api_response(content: "", tool_calls: [call]))
    agent.add_hook(:prepare_feedback) do |request|
      request[:questions] << { question: "Next step?", options: ["Discuss"] }
    end

    expect(agent.run("Ask me about the audience")).to include(awaiting_user_feedback: true)

    stored = agent.history.to_a.find { |message| message[:feedback_requests] }
    expect(stored.fetch(:feedback_requests).fetch(call[:id])[:questions].last[:question]).to eq("Next step?")
    expect(replay.first[:questions].last[:question]).to eq("Next step?")
  end

  it "keeps the request on its owning message when a hook appends history" do
    agent.add_hook(:prepare_feedback) do |_request|
      agent.history.append(role: "assistant", content: "Extension note")
    end

    agent.send(:act, [call], assistant_message: @assistant_message)

    expect(@assistant_message.fetch(:feedback_requests).fetch(call[:id])[:request_id]).to eq(call[:id])
    expect(agent.history.to_a.last[:content]).to eq("Extension note")
    expect(agent.history.to_a.last).not_to have_key(:feedback_requests)
    expect(replay.first[:request_id]).to eq(call[:id])
  end

  it "keeps an unextended Ask valid" do
    result = agent.send(:act, [call], assistant_message: @assistant_message)
    expect(result[:awaiting_feedback]).to be(true)
    expect(events.find { |event| event[:type] == "request_feedback" }[:questions].length).to eq(1)
  end
end
