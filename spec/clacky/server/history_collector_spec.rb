# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HistoryCollector do
  let(:events) { [] }
  let(:collector) { described_class.new("sess-1", events) }

  describe "#show_assistant_message" do
    it "carries created_at into the replayed event" do
      collector.show_assistant_message("hello", files: [], created_at: 1_700_000_000.5)

      expect(events.last).to include(
        type: "assistant_message",
        session_id: "sess-1",
        content: "hello",
        created_at: 1_700_000_000.5
      )
    end

    it "omits created_at when the stored message has none" do
      collector.show_assistant_message("hello", files: [])

      expect(events.last).not_to have_key(:created_at)
    end

    it "skips blank content" do
      collector.show_assistant_message("   ", files: [], created_at: 1_700_000_000.5)

      expect(events).to be_empty
    end
  end
end
