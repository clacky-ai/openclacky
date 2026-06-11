# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Regression: an image-only user message (a single `image_url` content block,
# no accompanying text, no display_files) used to be dropped on replay.
#
# `is_real_user_msg` decided whether an array-content user message starts a
# replay round by checking its blocks against a type allow-list. The list was
# %w[text image] and did NOT include "image_url", so a message whose ONLY block
# is an image_url (user sent a picture and typed nothing) was judged "not a real
# user message", started no round, and vanished when the session was reopened.
#
# Trigger condition: user sends an image with no text, stored as a lone
# image_url block with empty display_files. Adding "image_url" to the allow-list
# makes the message start a round so the image is recovered from the block.
RSpec.describe "replay_history image-only user message" do
  # Minimal agent stub that includes SessionSerializer (mirrors session_replay_chunk_spec)
  def build_agent(messages)
    history = Clacky::MessageHistory.new(messages)

    agent_class = Class.new do
      include Clacky::Agent::SessionSerializer

      def initialize(history)
        @history = history
        @skill_loader = Object.new.tap { |sl| sl.define_singleton_method(:load_all) {} }
      end

      def build_system_prompt; "system"; end
    end

    agent_class.new(history)
  end

  # Collector that captures user messages WITH their files (so we can assert the
  # image was rendered, not just that the message survived).
  class ImageCollector
    attr_reader :user_messages

    def initialize
      @user_messages = []
    end

    def show_user_message(content, created_at: nil, files: [])
      @user_messages << { content: content, files: files }
    end

    def show_assistant_message(*); end
    def show_tool_call(*); end
    def show_tool_result(*); end
    def show_token_usage(*); end
    def method_missing(*); end
    def respond_to_missing?(*); true; end
  end

  # A lone image_url block carrying an inline data_url + image_path — exactly the
  # shape stored at send-time for an image-only message.
  let(:image_block) do
    {
      type: "image_url",
      image_url: { url: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC" },
      image_path: "/tmp/img_001.png"
    }
  end

  it "renders an image-only user message (single image_url block, no text)" do
    messages = [
      { role: "system", content: "You are helpful." },
      { role: "user", content: [image_block], created_at: Time.now.to_f }
    ]

    agent = build_agent(messages)
    collector = ImageCollector.new
    agent.replay_history(collector)

    # The message must survive replay …
    expect(collector.user_messages.size).to eq(1)
    # … and carry the recovered image so the UI can render it.
    files = collector.user_messages.first[:files]
    expect(files).not_to be_empty
    expect(files.first[:data_url]).to start_with("data:image/png")
  end

  it "still renders an image_url message that also has text (control)" do
    messages = [
      { role: "system", content: "You are helpful." },
      { role: "user",
        content: [{ type: "text", text: "what is this?" }, image_block],
        created_at: Time.now.to_f }
    ]

    agent = build_agent(messages)
    collector = ImageCollector.new
    agent.replay_history(collector)

    expect(collector.user_messages.size).to eq(1)
    expect(collector.user_messages.first[:content]).to include("what is this?")
    expect(collector.user_messages.first[:files]).not_to be_empty
  end

  it "does NOT treat a tool_result-only array as a user message" do
    messages = [
      { role: "system", content: "You are helpful." },
      { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }],
        created_at: Time.now.to_f }
    ]

    agent = build_agent(messages)
    collector = ImageCollector.new
    agent.replay_history(collector)

    # A bare tool_result array is not a real user turn → starts no round.
    expect(collector.user_messages).to be_empty
  end
end
