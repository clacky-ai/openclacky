# frozen_string_literal: true

require "clacky/server/http_server"

RSpec.describe "channel prompt prefix stripping on replay" do
  let(:directory) { Dir.mktmpdir("sender-strip-spec") }
  let(:events) { [] }
  let(:collector) { Clacky::Server::HistoryCollector.new("strip-test", events) }

  after { FileUtils.rm_rf(directory) }

  def agent_for(messages, channel_info: nil)
    Class.new do
      include Clacky::Agent::SessionSerializer
      attr_reader :history
      attr_accessor :channel_info
      def initialize(messages)
        @history = Clacky::MessageHistory.new(messages)
      end
    end.new(messages).tap { |a| a.channel_info = channel_info }
  end

  def user(text, time = 1, **extra)
    { role: "user", content: text, created_at: time }.merge(extra)
  end

  def assistant(text, **options)
    { role: "assistant", content: text }.merge(options)
  end

  def chunk(number, user_body)
    path = File.join(directory, "session-chunk-#{number}.md")
    File.write(path, "---\narchived_at: 2026-03-01T10:00:00Z\n---\n## User\n\n#{user_body}\n\n## Assistant\n\nok\n")
    path
  end

  def all_entries(agent)
    agent.history_navigation[:sources].flat_map do |source|
      Array.new(source[:count]) do |offset|
        id = JSON.generate([source[:key], offset, source[:version], source[:identities]&.[](offset)])
        agent.history_navigation_preview(id: id)
      end
    end
  end

  let(:channel_info) { { platform: "feishu", user_id: "ou_abc", chat_id: "oc_1" } }
  let(:single_chat_prompt) { "[Sender: ou_abc]\n你好" }
  let(:group_chat_prompt) {
    "[Group chat history (2 messages)]\nou_a: 早\nou_b: 午\n---\n[Sender: ou_abc]\n你好"
  }

  describe "replay_history fallback to raw content" do
    it "strips the single-chat Sender line for channel sessions" do
      agent = agent_for([user(single_chat_prompt)], channel_info: channel_info)
      agent.replay_history(collector)
      expect(events.first[:content]).to eq("你好")
    end

    it "strips the whole group-chat context block for channel sessions" do
      agent = agent_for([user(group_chat_prompt)], channel_info: channel_info)
      agent.replay_history(collector)
      expect(events.first[:content]).to eq("你好")
    end

    it "keeps a literal prefix typed by a non-channel user" do
      agent = agent_for([user(single_chat_prompt)])
      agent.replay_history(collector)
      expect(events.first[:content]).to eq(single_chat_prompt)
    end

    it "prefers display_text when present" do
      agent = agent_for([user(single_chat_prompt, display_text: "你好")], channel_info: channel_info)
      agent.replay_history(collector)
      expect(events.first[:content]).to eq("你好")
    end
  end

  describe "chunk MD replay" do
    it "strips the Sender line from archived user sections of channel sessions" do
      path = chunk(1, single_chat_prompt)
      agent = agent_for(
        [assistant("summary", compressed_summary: true, chunk_path: path)],
        channel_info: channel_info
      )
      agent.replay_history(collector)
      expect(events.first[:content]).to eq("你好")
    end

    it "keeps archived content untouched for non-channel sessions" do
      path = chunk(1, single_chat_prompt)
      agent = agent_for([assistant("summary", compressed_summary: true, chunk_path: path)])
      agent.replay_history(collector)
      expect(events.first[:content]).to eq(single_chat_prompt)
    end
  end

  describe "navigation previews" do
    it "strips the prefix in channel session previews" do
      agent = agent_for([user(single_chat_prompt)], channel_info: channel_info)
      expect(all_entries(agent).first[:user]).to eq("你好")
    end

    it "keeps the prefix in non-channel previews" do
      agent = agent_for([user(single_chat_prompt)])
      expect(all_entries(agent).first[:user]).to start_with("[Sender:")
    end
  end
end
