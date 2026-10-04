# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"

RSpec.describe Clacky::Channel::ChannelUIController, "issue #603 web reply after a finished Feishu card" do
  let(:sent) { [] }
  let(:adapter) do
    Class.new do
      attr_reader :updates

      def initialize(sink)
        @sink = sink
        @updates = []
        @next_id = 0
      end

      def platform_id
        :feishu
      end

      def send_text(chat_id, text, reply_to: nil)
        @sink << [:text, chat_id, text, reply_to]
      end

      def send_progress(chat_id, text, reply_to: nil, state: nil)
        id = "card-#{@next_id += 1}"
        { progress_id: id }
      end

      def update_progress(chat_id, progress_id, text, state: nil, content: nil, history: nil)
        @updates << [progress_id, state]
        true
      end

      def supports_progress_updates?
        true
      end

      def flush_pending(_chat_id); end
    end.new(sent)
  end

  def build_controller
    Clacky::Channel::ChannelUIController.new(
      { platform: :feishu, chat_id: "oc_chat", message_id: "om_initial" },
      -> { adapter },
      -> { true },  # status messages
      -> { false }, # process messages
      -> { true }   # progress cards
    )
  end

  it "delivers the agent reply to IM after a prior Feishu card has finished (web follow-up)" do
    ui = build_controller

    # 1) A Feishu-initiated task: context set, card started, then task completes.
    ui.update_message_context(chat_id: "oc_chat", message_id: "om_1")
    expect(ui.start_task).to eq(true)

    ui.show_assistant_message("done from feishu", files: [])
    expect(sent.map { |m| m[0] }).not_to include(:text) # delivered via card, no standalone text

    # The card is now in a terminal state but still referenced.
    # 2) User switches to the web client and sends a new message.
    ui.show_user_message("follow up from web")

    # 3) The agent's final reply MUST reach the IM channel.
    ui.show_assistant_message("answer from web", files: [])

    texts = sent.select { |m| m[0] == :text }.map { |m| m[2] }
    expect(texts).to include("answer from web")
  end
end
