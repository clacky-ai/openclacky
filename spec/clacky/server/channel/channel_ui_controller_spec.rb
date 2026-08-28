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
