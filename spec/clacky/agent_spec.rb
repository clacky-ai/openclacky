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

  describe "#observe" do
    it "maintains tool results in same order as tool_calls" do
      # Simulate a response with multiple tool calls
      response = {
        tool_calls: [
          { id: "call_1", type: "function", function: { name: "tool_a", arguments: "{}" } },
          { id: "call_2", type: "function", function: { name: "tool_b", arguments: "{}" } },
          { id: "call_3", type: "function", function: { name: "tool_c", arguments: "{}" } }
        ]
      }

      # Tool results arrive in different order (e.g., due to concurrent execution)
      tool_results = [
        { id: "call_3", content: JSON.generate({ result: "C" }) },
        { id: "call_1", content: JSON.generate({ result: "A" }) },
        { id: "call_2", content: JSON.generate({ result: "B" }) }
      ]

      # Call observe
      agent.send(:observe, response, tool_results)

      # Get the messages
      messages = agent.instance_variable_get(:@messages)
      tool_messages = messages.select { |m| m[:role] == "tool" }

      # Verify the order matches the original tool_calls order
      expect(tool_messages.size).to eq(3)
      expect(tool_messages[0][:tool_call_id]).to eq("call_1")
      expect(tool_messages[1][:tool_call_id]).to eq("call_2")
      expect(tool_messages[2][:tool_call_id]).to eq("call_3")
    end

    it "handles missing tool results with error fallback" do
      response = {
        tool_calls: [
          { id: "call_1", type: "function", function: { name: "tool_a", arguments: "{}" } },
          { id: "call_2", type: "function", function: { name: "tool_b", arguments: "{}" } }
        ]
      }

      # Only one result provided
      tool_results = [
        { id: "call_1", content: JSON.generate({ result: "A" }) }
      ]

      agent.send(:observe, response, tool_results)

      messages = agent.instance_variable_get(:@messages)
      tool_messages = messages.select { |m| m[:role] == "tool" }

      expect(tool_messages.size).to eq(2)
      expect(tool_messages[0][:tool_call_id]).to eq("call_1")
      expect(tool_messages[1][:tool_call_id]).to eq("call_2")
      
      # Second message should be an error
      error_content = JSON.parse(tool_messages[1][:content])
      expect(error_content["error"]).to eq("Tool result missing")
    end
  end

  describe "message compression" do
    let(:compression_config) do
      Clacky::AgentConfig.new(
        model: "gpt-3.5-turbo",
        permission_mode: :auto_approve,
        max_iterations: 50,
        enable_compression: true,
        keep_recent_messages: 5
      )
    end
    let(:compression_agent) { described_class.new(client, compression_config) }

    it "compresses messages when threshold is exceeded" do
      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "done"))

      # Add many messages to trigger compression
      messages = compression_agent.instance_variable_get(:@messages)
      messages << { role: "system", content: "System prompt" }
      15.times do |i|
        messages << { role: "user", content: "Message #{i}" }
        messages << { role: "assistant", content: "Response #{i}" }
      end

      initial_count = messages.size
      compression_agent.send(:compress_messages_if_needed)
      final_count = compression_agent.instance_variable_get(:@messages).size

      expect(final_count).to be < initial_count
      expect(final_count).to be <= (compression_config.keep_recent_messages + 2) # +2 for system and summary
    end

    it "preserves system message during compression" do
      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "done"))

      messages = compression_agent.instance_variable_get(:@messages)
      messages << { role: "system", content: "Important system prompt" }
      15.times { |i| messages << { role: "user", content: "Msg #{i}" } }

      compression_agent.send(:compress_messages_if_needed)
      compressed_messages = compression_agent.instance_variable_get(:@messages)

      system_msg = compressed_messages.find { |m| m[:role] == "system" }
      expect(system_msg).not_to be_nil
      expect(system_msg[:content]).to eq("Important system prompt")
    end

    it "can be disabled via config" do
      no_compression_config = Clacky::AgentConfig.new(
        permission_mode: :auto_approve,
        enable_compression: false,
        keep_recent_messages: 5
      )
      no_compression_agent = described_class.new(client, no_compression_config)

      messages = no_compression_agent.instance_variable_get(:@messages)
      20.times { |i| messages << { role: "user", content: "Msg #{i}" } }

      initial_count = messages.size
      no_compression_agent.send(:compress_messages_if_needed)
      final_count = no_compression_agent.instance_variable_get(:@messages).size

      expect(final_count).to eq(initial_count) # No compression
    end

    it "preserves all tool results when assistant has multiple tool_calls" do
      allow(client).to receive(:send_messages_with_tools)
        .and_return(mock_api_response(content: "done"))

      messages = compression_agent.instance_variable_get(:@messages)
      messages << { role: "system", content: "System" }
      
      # Add many messages to trigger compression
      10.times do |i|
        messages << { role: "user", content: "Request #{i}" }
        messages << { role: "assistant", content: "Response #{i}" }
      end

      # Add a critical scenario: assistant with MULTIPLE tool_calls
      messages << { role: "user", content: "Do two things" }
      messages << {
        role: "assistant",
        content: nil,
        tool_calls: [
          { id: "call_1", type: "function", function: { name: "tool_a", arguments: "{}" } },
          { id: "call_2", type: "function", function: { name: "tool_b", arguments: "{}" } }
        ]
      }
      # Add the two corresponding tool results
      messages << { role: "tool", tool_call_id: "call_1", content: "Result A" }
      messages << { role: "tool", tool_call_id: "call_2", content: "Result B" }
      
      # Add a final message to be preserved
      messages << { role: "user", content: "Final request" }

      compression_agent.send(:compress_messages_if_needed)
      compressed = compression_agent.instance_variable_get(:@messages)

      # Find the assistant message with multiple tool_calls
      assistant_msg = compressed.find do |m|
        m[:role] == "assistant" && m[:tool_calls]&.size == 2
      end

      if assistant_msg
        # If the assistant message is preserved, ALL its tool results must be preserved
        tool_call_ids = assistant_msg[:tool_calls].map { |tc| tc[:id] }
        tool_results = compressed.select { |m| m[:role] == "tool" && tool_call_ids.include?(m[:tool_call_id]) }
        
        expect(tool_results.size).to eq(2), 
          "Expected 2 tool results for assistant with 2 tool_calls, but found #{tool_results.size}"
        expect(tool_results.map { |m| m[:tool_call_id] }.sort).to eq(["call_1", "call_2"].sort)
      end
    end
  end
end
