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
    described_class.new(event, -> { adapter }, -> { @status_enabled })
  end

  before { @status_enabled = true }

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
    it "flushes buffered previews when status messages are enabled" do
      controller.buffer_line("create: a.rb")
      controller.buffer_line("$ ls")
      controller.flush_buffer
      expect(sent).to eq(["create: a.rb\n$ ls"])
    end

    it "drops previews when status messages are disabled" do
      @status_enabled = false
      controller.buffer_line("create: a.rb")
      controller.buffer_line("$ ls")
      controller.flush_buffer
      expect(sent).to be_empty
    end
  end

  describe "#show_warning" do
    it "still sends warnings when status messages are disabled" do
      @status_enabled = false
      controller.show_warning("disk almost full")
      expect(sent).to eq(["Warning: disk almost full"])
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
