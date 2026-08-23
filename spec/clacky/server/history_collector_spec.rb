# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HistoryCollector do
  it "returns created_at on assistant message events" do
    events = []
    collector = described_class.new("session-1", events)

    collector.show_assistant_message(
      "Done",
      files: [],
      created_at: 1_700_000_000.25
    )

    expect(events).to contain_exactly(
      type: "assistant_message",
      session_id: "session-1",
      content: "Done",
      created_at: 1_700_000_000.25
    )
  end
end
