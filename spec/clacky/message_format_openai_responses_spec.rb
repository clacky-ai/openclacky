# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Clacky::MessageFormat::OpenAIResponses do
  let(:model) { "gpt-4o" }
  let(:tools) { [] }
  let(:max_tokens) { 1024 }

  describe ".build_request_body" do
    it "converts plain text messages to input items" do
      messages = [
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Hi there!" }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      expect(body[:model]).to eq(model)
      expect(body[:max_output_tokens]).to eq(max_tokens)
      expect(body[:input]).to be_an(Array)
      expect(body[:input].length).to eq(2)
      expect(body[:input][0][:type]).to eq("message")
      expect(body[:input][0][:role]).to eq("user")
      expect(body[:input][0][:content]).to eq("Hello")
    end

    it "converts system messages to developer role" do
      messages = [
        { role: "system", content: "You are a helpful assistant." },
        { role: "user", content: "Hi" }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      expect(body[:input][0][:role]).to eq("developer")
      expect(body[:input][0][:content]).to eq("You are a helpful assistant.")
    end

    it "uses max_output_tokens instead of max_tokens" do
      body = described_class.build_request_body([], model, tools, max_tokens, false)
      expect(body[:max_output_tokens]).to eq(max_tokens)
      expect(body).not_to have_key(:max_tokens)
    end

    it "converts array content text blocks to input_text" do
      messages = [
        { role: "user", content: [{ type: "text", text: "Hello" }] }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      content = body[:input][0][:content]
      expect(content).to be_an(Array)
      expect(content[0][:type]).to eq("input_text")
      expect(content[0][:text]).to eq("Hello")
    end

    it "converts image_url blocks to input_image when vision is supported" do
      messages = [
        { role: "user", content: [
          { type: "text", text: "Look at this:" },
          { type: "image_url", image_url: { url: "data:image/png;base64,abc123" } }
        ] }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      content = body[:input][0][:content]
      expect(content[0][:type]).to eq("input_text")
      expect(content[1][:type]).to eq("input_image")
      expect(content[1][:image_url][:url]).to eq("data:image/png;base64,abc123")
    end

    it "replaces image_url with text placeholder when vision is not supported" do
      messages = [
        { role: "user", content: [
          { type: "text", text: "Look at this:" },
          { type: "image_url", image_url: { url: "data:image/png;base64,abc123" } }
        ] }
      ]

      body = described_class.build_request_body(
        messages, model, tools, max_tokens, false, vision_supported: false
      )
      content = body[:input][0][:content]
      expect(content[0][:type]).to eq("input_text")
      expect(content[1][:type]).to eq("input_text")
      expect(content[1][:text]).to include("Image content removed")
    end

    it "splits assistant messages with tool_calls into message + function_call items" do
      messages = [
        { role: "user", content: "What is the weather?" },
        { role: "assistant", content: nil, tool_calls: [
          { id: "call_001", type: "function", name: "get_weather", arguments: "{\"city\":\"Tokyo\"}" }
        ] }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      # User message -> 1 item, assistant (nil content, only tool_calls) -> 1 function_call
      expect(body[:input].length).to eq(2)
      expect(body[:input][1][:type]).to eq("function_call")
      expect(body[:input][1][:call_id]).to eq("call_001")
      expect(body[:input][1][:name]).to eq("get_weather")
      expect(body[:input][1][:arguments]).to eq("{\"city\":\"Tokyo\"}")
    end

    it "handles nested tool_calls format (as stored in history)" do
      messages = [
        { role: "user", content: "What is the weather?" },
        { role: "assistant", content: nil, tool_calls: [
          { id: "call_002", type: "function", function: { name: "get_weather", arguments: "{\"city\":\"London\"}" } }
        ] }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      expect(body[:input].length).to eq(2)
      expect(body[:input][1][:type]).to eq("function_call")
      expect(body[:input][1][:call_id]).to eq("call_002")
      expect(body[:input][1][:name]).to eq("get_weather")
      expect(body[:input][1][:arguments]).to eq("{\"city\":\"London\"}")
    end

    it "converts tool result messages to function_call_output items" do
      messages = [
        { role: "user", content: "What is the weather?" },
        { role: "assistant", content: nil, tool_calls: [
          { id: "call_001", type: "function", name: "get_weather", arguments: "{\"city\":\"Tokyo\"}" }
        ] },
        { role: "tool", tool_call_id: "call_001", content: '{"temp": 25}' }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      # The last item should be function_call_output
      last = body[:input].last
      expect(last[:type]).to eq("function_call_output")
      expect(last[:call_id]).to eq("call_001")
      expect(last[:output]).to eq("{\"temp\": 25}")
    end

    it "includes tools array when tools are present" do
      tools = [{
        type: "function",
        function: {
          name: "get_weather",
          description: "Get weather for a city",
          parameters: { type: "object", properties: {} }
        }
      }]

      body = described_class.build_request_body([{ role: "user", content: "Hi" }], model, tools, max_tokens, false)
      expect(body[:tools]).to be_an(Array)
      expect(body[:tools].length).to eq(1)
      expect(body[:tools][0][:name]).to eq("get_weather")
      expect(body[:tools][0][:description]).to eq("Get weather for a city")
      expect(body[:tools][0]).not_to have_key(:function)
    end

    it "adds cache_control to last tool when caching is enabled" do
      tools = [
        { type: "function", function: { name: "tool_a", parameters: {} } },
        { type: "function", function: { name: "tool_b", parameters: {} } }
      ]

      body = described_class.build_request_body([{ role: "user", content: "Hi" }], model, tools, max_tokens, true)
      expect(body[:tools].last[:cache_control]).to eq({ type: "ephemeral" })
      expect(body[:tools].first).not_to have_key(:cache_control)
    end

    it "does not mutate the original tools array when caching" do
      tools = [
        { type: "function", function: { name: "tool_a", parameters: {} } }
      ]

      described_class.build_request_body([{ role: "user", content: "Hi" }], model, tools, max_tokens, true)
      expect(tools.first).not_to have_key(:cache_control)
    end

    it "passes through tools already in flat Responses API format" do
      tools = [{
        type: "function",
        name: "get_weather",
        description: "Get weather",
        parameters: { type: "object", properties: {} }
      }]

      body = described_class.build_request_body([{ role: "user", content: "Hi" }], model, tools, max_tokens, false)
      expect(body[:tools][0][:name]).to eq("get_weather")
      expect(body[:tools][0]).not_to have_key(:function)
    end
  end

  describe ".parse_response" do
    it "extracts text content from output_text blocks" do
      data = {
        "status" => "completed",
        "output" => [
          {
            "type" => "message",
            "role" => "assistant",
            "content" => [
              { "type" => "output_text", "text" => "Hello, " },
              { "type" => "output_text", "text" => "world!" }
            ]
          }
        ],
        "usage" => {
          "input_tokens" => 10,
          "output_tokens" => 5
        }
      }

      result = described_class.parse_response(data)
      expect(result[:content]).to eq("Hello, world!")
      expect(result[:tool_calls]).to be_nil
      expect(result[:finish_reason]).to eq("stop")
    end

    it "extracts function calls from function_call output items" do
      data = {
        "status" => "completed",
        "output" => [
          {
            "type" => "function_call",
            "call_id" => "call_abc",
            "name" => "get_weather",
            "arguments" => "{\"city\":\"Paris\"}"
          }
        ],
        "usage" => { "input_tokens" => 10, "output_tokens" => 20 }
      }

      result = described_class.parse_response(data)
      expect(result[:tool_calls]).to be_an(Array)
      expect(result[:tool_calls].length).to eq(1)
      expect(result[:tool_calls][0][:id]).to eq("call_abc")
      expect(result[:tool_calls][0][:name]).to eq("get_weather")
      expect(result[:tool_calls][0][:arguments]).to eq("{\"city\":\"Paris\"}")
      expect(result[:finish_reason]).to eq("tool_calls")
    end

    it "maps usage fields correctly" do
      data = {
        "status" => "completed",
        "output" => [],
        "usage" => {
          "input_tokens" => 100,
          "output_tokens" => 50,
          "total_tokens" => 150
        }
      }

      result = described_class.parse_response(data)
      expect(result[:usage][:prompt_tokens]).to eq(100)
      expect(result[:usage][:completion_tokens]).to eq(50)
      expect(result[:usage][:total_tokens]).to eq(150)
    end

    it "calculates total_tokens when not provided" do
      data = {
        "status" => "completed",
        "output" => [],
        "usage" => { "input_tokens" => 30, "output_tokens" => 20 }
      }

      result = described_class.parse_response(data)
      expect(result[:usage][:total_tokens]).to eq(50)
    end

    it "extracts cache info from input_tokens_details" do
      data = {
        "status" => "completed",
        "output" => [],
        "usage" => {
          "input_tokens" => 100,
          "output_tokens" => 50,
          "input_tokens_details" => { "cached_tokens" => 80 }
        }
      }

      result = described_class.parse_response(data)
      expect(result[:usage][:cache_read_input_tokens]).to eq(80)
    end

    it "extracts reasoning tokens from output_tokens_details" do
      data = {
        "status" => "completed",
        "output" => [],
        "usage" => {
          "input_tokens" => 100,
          "output_tokens" => 50,
          "output_tokens_details" => { "reasoning_tokens" => 30 }
        }
      }

      result = described_class.parse_response(data)
      expect(result[:usage][:reasoning_tokens]).to eq(30)
    end

    it "returns 'length' finish_reason for incomplete status" do
      data = {
        "status" => "incomplete",
        "output" => [{ "type" => "message", "content" => [{ "type" => "output_text", "text" => "partial" }] }],
        "usage" => {}
      }

      result = described_class.parse_response(data)
      expect(result[:finish_reason]).to eq("length")
    end

    it "preserves raw_api_usage" do
      usage = { "input_tokens" => 10, "output_tokens" => 5 }
      data = { "status" => "completed", "output" => [], "usage" => usage }

      result = described_class.parse_response(data)
      expect(result[:raw_api_usage]).to eq(usage)
    end
  end

  describe ".format_tool_results" do
    it "builds canonical tool messages from tool call results" do
      response = {
        tool_calls: [
          { id: "call_001", name: "get_weather", arguments: "{\"city\":\"Tokyo\"}" }
        ]
      }
      tool_results = [
        { id: "call_001", content: '{"temp": 25}' }
      ]

      messages = described_class.format_tool_results(response, tool_results)
      expect(messages.length).to eq(1)
      expect(messages[0][:role]).to eq("tool")
      expect(messages[0][:tool_call_id]).to eq("call_001")
      expect(messages[0][:content]).to eq("{\"temp\": 25}")
    end

    it "handles missing tool results gracefully" do
      response = {
        tool_calls: [
          { id: "call_001", name: "get_weather", arguments: "{}" }
        ]
      }
      tool_results = []

      messages = described_class.format_tool_results(response, tool_results)
      expect(messages[0][:content]).to include("Tool result missing")
    end
  end

  describe ".apply_reasoning_params" do
    it "applies thinking params for GLM models" do
      body = {}
      described_class.build_request_body(
        [{ role: "user", content: "Hi" }], "glm-4-plus", [], 100, false,
        reasoning_effort: "high"
      )
      # The method is called internally; verify via build_request_body
    end

    it "applies reasoning_effort for deepseek models" do
      body = described_class.build_request_body(
        [{ role: "user", content: "Hi" }], "deepseek-r1", [], 100, false,
        reasoning_effort: "high"
      )
      expect(body[:reasoning_effort]).to eq("high")
    end
  end
end
