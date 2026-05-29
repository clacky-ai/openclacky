# frozen_string_literal: true

# Business-logic tests for the Bedrock streaming truncation recovery.
#
# Background:
#   AWS Bedrock occasionally streams tool call arguments that stop mid-JSON
#   (e.g. only 18 tokens: '{"path": "/tmp/build_manual.py"' — no `content`).
#   When this happens, ArgumentsParser raises BadArgumentsError.
#
#   BadArgumentsError is treated as a normal tool error: the assistant message
#   stays in history and a tool_result with the error message is appended.
#   The LLM sees the error feedback and naturally adjusts on the next attempt.

RSpec.describe Clacky::Agent, "Bedrock truncated tool call recovery" do
  # ── helpers ──────────────────────────────────────────────────────────────────

  let(:config) do
    Clacky::AgentConfig.new(
      models: [{
        "type"             => "default",
        "model"            => "abs-claude-sonnet-4-6",
        "api_key"          => "absk-test",
        "base_url"         => "https://api.openclacky.com/v1",
        "anthropic_format" => true
      }],
      permission_mode: :auto_approve
    )
  end

  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      # instance_double proxies don't store instance variables — stub the accessor directly
      allow(c).to receive(:instance_variable_get).with(:@api_key).and_return("absk-test")
      allow(c).to receive(:bedrock?).and_return(true)
      allow(c).to receive(:anthropic_format?).and_return(true)
      allow(c).to receive(:supports_prompt_caching?).and_return(false)
      allow(c).to receive(:format_tool_results) do |_response, tool_results, **_|
        # Emit one "tool" role message per result, mirroring real behaviour
        tool_results.map { |r| { role: "tool", tool_call_id: r[:id], content: r[:content] } }
      end
    end
  end

  let(:agent) do
    described_class.new(
      client, config,
      working_dir: Dir.pwd,
      ui: nil,
      profile: "general",
      session_id: Clacky::SessionManager.generate_id,
      source: :manual
    )
  end

  # Build the kind of tool_call response Bedrock returns with truncated args
  def truncated_write_call(id: "toolu_bdrk_truncated_01")
    {
      id: id,
      type: "function",
      name: "write",
      # Only path, no content — exactly what was observed in the real session
      arguments: '{"path": "/tmp/build_manual.py"'
    }
  end

  def complete_write_call(id: "toolu_bdrk_complete_01")
    {
      id: id,
      type: "function",
      name: "write",
      arguments: '{"path": "/tmp/build_manual.py", "content": "print(\'hello\')\n"}'
    }
  end

  before do
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  # ── Scenario 1: history is clean after truncated call ────────────────────────

  describe "Scenario 1 — truncated write args: error returned as normal tool result" do
    # LLM returns the truncated tool call once, then a plain text final answer
    before do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        case call_count
        when 1
          # Bedrock truncates: only path, no content
          mock_api_response(
            content: "",
            tool_calls: [truncated_write_call]
          )
        else
          # Second call: LLM recovers and gives a plain answer
          mock_api_response(content: "Done.")
        end
      end
    end

    it "completes without raising" do
      expect { agent.run("Write a build script") }.not_to raise_error
    end

    it "returns the parse error as a tool result so LLM can see the feedback" do
      agent.run("Write a build script")

      tool_msgs = agent.history.to_a.select { |m| m[:role] == "tool" }
      expect(tool_msgs.size).to eq(1)
      error_content = JSON.parse(tool_msgs.first[:content])
      expect(error_content["error"]).to include("write")
    end

    it "does not leave orphan tool-result messages in history" do
      agent.run("Write a build script")

      # An orphan tool-result has no preceding assistant message with a matching tool_call id.
      # Verify: every tool message has a corresponding tool_call in the previous assistant.
      messages = agent.history.to_a
      messages.each_with_index do |msg, i|
        next unless msg[:role] == "tool"

        tool_call_id = msg[:tool_call_id]
        assistant = messages[0...i].reverse.find { |m| m[:role] == "assistant" }
        expect(assistant).not_to be_nil, "orphan tool message found at index #{i}"
        matched = assistant[:tool_calls]&.any? { |tc| tc[:id] == tool_call_id || tc.dig(:function, :id) == tool_call_id }
        expect(matched).to be(true), "tool_result #{tool_call_id} has no matching tool_call in history"
      end
    end

    it "makes exactly 2 LLM calls: once for the truncated turn, once for recovery" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        call_count == 1 ? mock_api_response(content: "", tool_calls: [truncated_write_call]) : mock_api_response(content: "Done.")
      end

      agent.run("Write a build script")
      expect(call_count).to eq(2)
    end
  end

  # ── Scenario 2: normal tool error keeps history intact ────────────────────────

  describe "Scenario 2 — normal runtime error (file permission denied): history NOT retracted" do
    # Write tool raises a permission error — this is NOT a BadArgumentsError,
    # so the assistant message must stay in history and the error result must be appended.
    before do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        case call_count
        when 1
          mock_api_response(
            content: "",
            tool_calls: [complete_write_call]
          )
        else
          mock_api_response(content: "Okay, noted the permission error.")
        end
      end

      # Make the write tool itself fail with a permission error
      write_tool = agent.instance_variable_get(:@tool_registry).get("write")
      allow(write_tool).to receive(:execute).and_raise(Errno::EACCES, "/tmp/build_manual.py")
    end

    it "keeps the assistant message in history after a runtime tool error" do
      agent.run("Write a build script")

      assistant_msgs = agent.history.to_a.select { |m| m[:role] == "assistant" && m[:tool_calls]&.any? }
      expect(assistant_msgs).not_to be_empty
    end

    it "appends the error tool-result message for the LLM to read" do
      agent.run("Write a build script")

      tool_msgs = agent.history.to_a.select { |m| m[:role] == "tool" }
      expect(tool_msgs).not_to be_empty
      error_content = JSON.parse(tool_msgs.first[:content])
      expect(error_content["error"]).to include("write")
    end
  end

  # ── Scenario 3: second attempt succeeds after truncation ──────────────────────

  describe "Scenario 3 — LLM retries with complete args and file is written" do
    let(:tmp_path) { File.join(Dir.tmpdir, "bedrock_recovery_test_#{SecureRandom.hex(4)}.py") }

    after { File.delete(tmp_path) if File.exist?(tmp_path) }

    before do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        case call_count
        when 1
          # Bedrock truncation on first attempt
          mock_api_response(
            content: "",
            tool_calls: [{
              id: "toolu_bdrk_truncated",
              type: "function",
              name: "write",
              arguments: "{\"path\": \"#{tmp_path}\""  # truncated — no content
            }]
          )
        when 2
          # Recovery: LLM regenerates with full args
          mock_api_response(
            content: "",
            tool_calls: [{
              id: "toolu_bdrk_complete",
              type: "function",
              name: "write",
              arguments: "{\"path\": \"#{tmp_path}\", \"content\": \"print('hello')\\n\"}"
            }]
          )
        else
          mock_api_response(content: "Script written successfully.")
        end
      end
    end

    it "successfully writes the file on the second attempt" do
      agent.run("Write a Python hello-world script")
      expect(File.exist?(tmp_path)).to be true
      expect(File.read(tmp_path)).to include("print")
    end

    it "finishes with a success status" do
      result = agent.run("Write a Python hello-world script")
      expect(result[:status]).to eq(:success)
    end
  end

  # ── Scenario 4: multiple consecutive truncations don't loop forever ────────────

  describe "Scenario 4 — repeated Bedrock truncation: agent eventually gives up or recovers" do
    before do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        # Truncate 3 times, then plain answer
        if call_count <= 3
          mock_api_response(content: "", tool_calls: [truncated_write_call(id: "toolu_bdrk_t#{call_count}")])
        else
          mock_api_response(content: "I was unable to write the file.")
        end
      end
    end

    it "does not loop infinitely — terminates within reasonable iteration count" do
      result = agent.run("Write a build script")
      expect(result[:status]).to eq(:success)
    end

    it "returns error tool results so LLM gets feedback each time" do
      agent.run("Write a build script")

      tool_msgs = agent.history.to_a.select { |m| m[:role] == "tool" }
      # Each truncated tool call gets an error tool_result — LLM sees the feedback
      expect(tool_msgs).not_to be_empty
      tool_msgs.each do |msg|
        error_content = JSON.parse(msg[:content])
        expect(error_content).to have_key("error")
      end
    end
  end
end
