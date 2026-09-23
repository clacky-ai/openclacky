# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"

RSpec.describe Clacky::Channel::ChannelUIController do
  let(:sent) { [] }
  let(:adapter) do
    rec = sent
    double("adapter").tap do |a|
      allow(a).to receive(:send_text) { |_chat_id, text, _opts| rec << text }
    end
  end
  let(:event) { { platform: :feishu, chat_id: "chat_1", message_id: "msg_1" } }
  let(:controller) do
    described_class.new(event, -> { adapter }, -> { @status_enabled }, -> { @process_enabled })
  end

  before do
    @status_enabled  = true
    @process_enabled = true
  end

  def complete
    controller.show_complete(iterations: 1, cost: 0.0008, duration: 2.3, cost_source: :pricing)
  end

  describe "#show_complete" do
    it "sends the Done summary when status messages are enabled" do
      complete
      expect(sent.size).to eq(1)
      expect(sent.first).to match(/\ADone · 1 step · \$0\.0008 · 2\.3s\z/)
    end

    it "sends nothing when status messages are disabled" do
      @status_enabled = false
      complete
      expect(sent).to be_empty
    end
  end

  describe "task progress messages" do
    let(:progress_updates) { [] }
    let(:progress_details) { [] }
    let(:progress_adapter) do
      updates = progress_updates
      details = progress_details
      rec = sent
      double("progress adapter").tap do |a|
        allow(a).to receive(:supports_progress_updates?).and_return(true)
        allow(a).to receive(:send_progress).and_return(
          message_id: "progress_1",
          progress_id: "card_1"
        )
        allow(a).to receive(:update_progress) do |chat_id, message_id, text, state:, content: nil, history: nil|
          updates << [chat_id, message_id, text, state]
          details << { content: content, history: history }
          true
        end
        allow(a).to receive(:send_text) { |_chat_id, text, _opts| rec << text }
      end
    end
    let(:progress_controller) do
      described_class.new(event, -> { progress_adapter }, -> { @status_enabled }, -> { @process_enabled })
    end

    it "updates one progress message from thinking through working to the final reply" do
      expect(progress_controller.start_task).to be true
      expect(progress_adapter).to have_received(:send_progress)
        .with("chat_1", "Thinking...", reply_to: "msg_1", state: :running)

      progress_controller.show_tool_call("terminal", { "command" => "ls" })
      progress_controller.show_tool_call("write", { "path" => "a.rb" })
      progress_controller.show_assistant_message("All done", files: [])
      progress_controller.show_complete(iterations: 2, cost: nil, duration: 1.2, cost_source: nil)

      expect(progress_updates).to eq([
        ["chat_1", "card_1", "Running a command...", :working],
        ["chat_1", "card_1", "Writing a file...", :working],
        ["chat_1", "card_1", "All done", :success]
      ])
      expect(sent).to be_empty
    end

    it "keeps the generic working milestone when process messages are disabled" do
      @process_enabled = false
      progress_controller.start_task

      progress_controller.show_tool_call("terminal", { "command" => "ls" })
      progress_controller.show_tool_call("write", { "path" => "a.rb" })

      expect(progress_updates).to eq([
        ["chat_1", "card_1", "Working...", :working]
      ])
      expect(sent).to be_empty
    end

    it "replaces visible progress content and keeps narration in collapsible history" do
      progress_controller.start_task

      progress_controller.show_assistant_message(
        "Checking   the configuration...",
        files: [],
        interim: true
      )

      expect(progress_updates).to eq([
        ["chat_1", "card_1", "Working...", :working]
      ])
      expect(progress_details).to eq([
        {
          content: "Checking   the configuration...",
          history: "Checking   the configuration..."
        }
      ])
      expect(sent).to be_empty
    end

    it "shows only the latest narration while accumulating process history" do
      progress_controller.start_task

      progress_controller.show_assistant_message("First step", files: [], interim: true)
      progress_controller.show_assistant_message("Second step", files: [], interim: true)
      progress_controller.show_assistant_message("Final answer", files: [])

      expect(progress_details).to eq([
        { content: "First step", history: "First step" },
        { content: "Second step", history: "First step\n\nSecond step" },
        { content: "Final answer", history: "First step\n\nSecond step" }
      ])
      expect(progress_updates.last).to eq([
        "chat_1", "card_1", "Final answer", :success
      ])
      expect(sent).to be_empty
    end

    it "updates the progress card with existing process previews" do
      progress_controller.start_task

      progress_controller.buffer_line("$ bundle exec rspec")
      progress_controller.flush_buffer

      expect(progress_updates).to eq([
        ["chat_1", "card_1", "$ bundle exec rspec", :working]
      ])
      expect(sent).to be_empty
    end

    it "uses a safe generic status for unknown tools" do
      progress_controller.start_task

      progress_controller.show_tool_call("private_extension_tool", { "secret" => "value" })

      expect(progress_updates).to eq([
        ["chat_1", "card_1", "Working...", :working]
      ])
      expect(progress_updates.flatten.join).not_to include("private_extension_tool", "secret", "value")
    end

    it "continues suppressing tool results while process updates are enabled" do
      progress_controller.start_task

      progress_controller.show_tool_result("sensitive output")
      progress_controller.show_tool_args("secret arguments")

      expect(progress_updates).to be_empty
      expect(sent).to be_empty
    end

    it "ignores delayed process events after the progress card is finalized" do
      progress_controller.start_task
      progress_controller.show_assistant_message("Final result", files: [])

      progress_controller.show_tool_call("terminal", { "command" => "late command" })
      progress_controller.buffer_line("$ late command")
      progress_controller.show_assistant_message("late narration", files: [], interim: true)

      expect(progress_updates).to eq([
        ["chat_1", "card_1", "Final result", :success]
      ])
      expect(sent).to be_empty
    end

    it "falls back to a normal final message when the card update fails" do
      progress_controller.start_task
      allow(progress_adapter).to receive(:update_progress).and_return(false)

      progress_controller.show_assistant_message("Fallback result", files: [])

      expect(sent).to eq(["Fallback result"])
    end

    it "keeps the native card session after a transient milestone failure" do
      progress_controller.start_task
      attempts = 0
      allow(progress_adapter).to receive(:update_progress) do |chat_id, progress_id, text, state:, **details|
        progress_updates << [chat_id, progress_id, text, state]
        progress_details << details
        attempts += 1
        attempts > 1
      end

      progress_controller.show_tool_call("terminal", { "command" => "ls" })
      progress_controller.show_assistant_message("Final result", files: [])

      expect(progress_updates).to eq([
        ["chat_1", "card_1", "Running a command...", :working],
        ["chat_1", "card_1", "Final result", :success]
      ])
      expect(sent).to be_empty
    end

    it "updates the active progress message when the task is interrupted" do
      progress_controller.start_task

      expect(progress_controller.interrupt_task).to be true
      expect(progress_updates).to eq([
        ["chat_1", "card_1", "Task interrupted.", :interrupted]
      ])
    end

    it "marks the progress message as waiting when the agent requests feedback" do
      progress_controller.start_task

      progress_controller.show_complete(
        iterations: 1,
        cost: nil,
        duration: 1.2,
        cost_source: nil,
        awaiting_user_feedback: true
      )

      expect(progress_updates).to eq([
        ["chat_1", "card_1", "Waiting for your response.", :waiting]
      ])
      expect(sent).to be_empty
    end

    it "clears a previous task before starting with status messages disabled" do
      progress_controller.start_task
      progress_controller.show_assistant_message("First result", files: [])
      @status_enabled = false

      expect(progress_controller.start_task).to be false
      progress_controller.show_assistant_message("Second result", files: [])

      expect(sent).to eq(["Second result"])
    end

    it "keeps standalone status messages for adapters without progress updates" do
      expect(controller.start_task).to be false
      expect(sent).to eq(["Thinking..."])
      expect(adapter).to have_received(:send_text).with("chat_1", "Thinking...", reply_to: nil)
    end

    it "does not infer progress support from ordinary message editing" do
      allow(adapter).to receive(:supports_message_updates?).and_return(true)
      allow(adapter).to receive(:supports_progress_updates?).and_return(false)
      allow(adapter).to receive(:send_progress)
      allow(adapter).to receive(:update_progress)

      expect(controller.start_task).to be false

      expect(adapter).not_to have_received(:send_progress)
      expect(sent).to eq(["Thinking..."])
    end

    it "falls back to a standalone status when native card creation fails" do
      allow(progress_adapter).to receive(:send_progress).and_raise("scope missing")

      expect(progress_controller.start_task).to be false
      expect(sent).to eq(["Thinking..."])
    end

    it "sanitizes hidden reasoning before finalizing the progress card" do
      progress_controller.start_task

      progress_controller.show_assistant_message(
        "<think>private reasoning</think>\nVisible answer",
        files: []
      )

      expect(progress_updates).to eq([
        ["chat_1", "card_1", "Visible answer", :success]
      ])
      expect(sent).to be_empty
    end
  end

  describe "#buffer_line" do
    it "flushes buffered previews when process messages are enabled" do
      controller.buffer_line("create: a.rb")
      controller.buffer_line("$ ls")
      controller.flush_buffer
      expect(sent).to eq(["create: a.rb\n$ ls"])
    end

    it "drops previews when process messages are disabled" do
      @process_enabled = false
      controller.buffer_line("create: a.rb")
      controller.buffer_line("$ ls")
      controller.flush_buffer
      expect(sent).to be_empty
    end
  end

  describe "#show_assistant_message" do
    it "suppresses interim narration when process messages are disabled" do
      @process_enabled = false
      controller.show_assistant_message("checking auth...", files: [], interim: true)
      expect(sent).to be_empty
    end

    it "sends interim narration when process messages are enabled" do
      controller.show_assistant_message("checking auth...", files: [], interim: true)
      expect(sent).to eq(["checking auth..."])
    end

    it "flushes pending previews before interim narration" do
      controller.buffer_line("create: a.rb")
      controller.buffer_line("$ ls")
      controller.show_assistant_message("checking auth...", files: [], interim: true)
      expect(sent).to eq(["create: a.rb\n$ ls", "checking auth..."])
    end

    it "always sends the final reply regardless of process messages" do
      @process_enabled = false
      controller.show_assistant_message("done", files: [])
      expect(sent).to eq(["done"])
    end
  end

  describe "#show_warning" do
    it "still sends warnings when status messages are disabled" do
      @status_enabled = false
      controller.show_warning("disk almost full")
      expect(sent).to eq(["Warning: disk almost full"])
    end
  end

  describe "#show_tool_call" do
    let(:ask_args) do
      {
        "questions" => [
          { "question" => "语言选中文还是英文?", "options" => %w[中文 English] },
          { "question" => "输出格式选 Markdown 还是纯文本?", "options" => %w[Markdown 纯文本] }
        ]
      }
    end

    it "renders ask_user questions as text so IM users can answer" do
      controller.show_tool_call("ask_user", ask_args)
      expect(sent.size).to eq(1)
      expect(sent.first).to include("语言选中文还是英文?", "1. 中文", "2. English")
      expect(sent.first).to include("输出格式选 Markdown 还是纯文本?", "1. Markdown")
    end

    it "sends ask_user even when process messages are disabled" do
      @process_enabled = false
      controller.show_tool_call("ask_user", ask_args)
      expect(sent.size).to eq(1)
      expect(sent.first).to include("语言选中文还是英文?")
    end

    it "accepts a JSON string payload" do
      controller.show_tool_call("ask_user", JSON.generate(ask_args))
      expect(sent.first).to include("语言选中文还是英文?")
    end

    it "renders the retired request_user_feedback name too" do
      controller.show_tool_call("request_user_feedback", ask_args)
      expect(sent.first).to include("语言选中文还是英文?")
    end

    it "flushes pending previews before the question" do
      controller.buffer_line("$ ls")
      controller.show_tool_call("ask_user", ask_args)
      expect(sent).to eq(["$ ls", sent.last])
      expect(sent.last).to include("语言选中文还是英文?")
    end

    it "stays silent when ask_user carries no usable question" do
      controller.show_tool_call("ask_user", { "questions" => [] })
      expect(sent).to be_empty
    end

    it "still suppresses every other tool" do
      controller.show_tool_call("terminal", { "command" => "ls" })
      controller.show_tool_call("write", { "path" => "a.rb" })
      expect(sent).to be_empty
    end
  end

  describe "without a status_messages resolver" do
    it "defaults to not sending status messages" do
      controller = described_class.new(event, -> { adapter })
      controller.show_complete(iterations: 2, cost: nil, duration: nil, cost_source: nil)
      expect(sent).to eq([])
    end
  end
end
