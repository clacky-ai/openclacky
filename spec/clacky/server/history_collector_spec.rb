# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HistoryCollector do
  let(:events) { [] }
  let(:collector) { described_class.new("sess-1", events) }
  let(:tmpdir) { Dir.mktmpdir("history_collector_spec") }

  after { FileUtils.rm_rf(tmpdir) }

  describe "#show_user_message" do
    it "keeps existing non-image attachments clickable on replay" do
      file_path = File.join(tmpdir, "notes.md")
      File.write(file_path, "hello")

      collector.show_user_message("read this", files: [{ name: "notes.md", type: "file", path: file_path }])

      expect(events.last[:attachments]).to eq([{ name: "notes.md", type: "file", path: file_path }])
      expect(events.last).not_to have_key(:images)
    end

    it "keeps missing attachments visible without a stale click target" do
      collector.show_user_message("read this", files: [{ name: "gone.md", type: "file", path: "/missing/gone.md" }])

      expect(events.last[:attachments]).to eq([{ name: "gone.md", type: "file" }])
    end

    it "keeps replayed images on the lightbox path" do
      image_path = File.join(tmpdir, "cover.png")
      File.binwrite(image_path, "PNG")

      collector.show_user_message("", files: [{ name: "cover.png", type: "image", path: image_path }])

      expect(events.last[:images].first).to start_with("/api/local-image?path=")
      expect(events.last).not_to have_key(:attachments)
    end
  end

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
