# frozen_string_literal: true

RSpec.describe Clacky::Agent do
  let(:client) { instance_double(Clacky::Client) }
  let(:config) do
    Clacky::AgentConfig.new(
      model: "gpt-3.5-turbo",
      permission_mode: :auto_approve,
      max_iterations: 5
    )
  end
  let(:agent) { described_class.new(client, config) }

  describe "#initialize" do
    it "registers built-in tools on initialization" do
      expect(agent.instance_variable_get(:@tool_registry).all.size).to eq(3)
    end

    it "sets initial state" do
      expect(agent.iterations).to eq(0)
      expect(agent.total_cost).to eq(0.0)
      expect(agent.session_id).to be_a(String)
    end
  end

  describe "#run" do
    let(:tool_call_response) do
      mock_api_response(
        content: nil,
        tool_calls: [mock_tool_call(name: "calculator", args: '{"expression":"1+1"}')]
      )
    end

    let(:final_response) do
      mock_api_response(content: "The result is 2")
    end

    before do
      allow(client).to receive(:send_messages_with_tools)
        .and_return(tool_call_response, final_response)
    end

    it "executes Think-Act-Observe loop" do
      result = agent.run("Calculate 1+1")

      expect(result[:status]).to eq(:success)
      expect(result[:iterations]).to be > 0
      expect(client).to have_received(:send_messages_with_tools).at_least(:once)
    end

    it "tracks iteration count" do
      agent.run("test")
      expect(agent.iterations).to be > 0
    end

    it "tracks cost" do
      agent.run("test")
      expect(agent.total_cost).to be > 0
    end

    it "triggers event callbacks" do
      events = []

      agent.run("test") do |event|
        events << event[:type]
      end

      expect(events).to include(:on_start)
      expect(events).to include(:thinking)
      expect(events).to include(:on_complete)
    end

    it "stops at maximum iterations" do
      # Make LLM always return tool calls
      allow(client).to receive(:send_messages_with_tools)
        .and_return(tool_call_response)

      short_config = Clacky::AgentConfig.new(
        permission_mode: :auto_approve,
        max_iterations: 2
      )
      short_agent = described_class.new(client, short_config)

      result = short_agent.run("test")

      expect(short_agent.iterations).to eq(2)
    end
  end

  describe "#add_hook" do
    it "allows adding hooks" do
      hook_called = false

      agent.add_hook(:on_start) do |input|
        hook_called = true
        expect(input).to eq("test input")
      end

      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "done"))

      agent.run("test input")

      expect(hook_called).to be true
    end
  end
end
