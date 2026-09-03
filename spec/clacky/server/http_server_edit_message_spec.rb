# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "editing historical messages" do
  subject(:server) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@registry, registry)
    end
  end

  let(:registry) { instance_double(Clacky::Server::SessionRegistry) }
  let(:history) { double("history") }
  let(:agent) { double("agent", history: history) }

  it "rejects edits before truncating history while the session is running" do
    allow(registry).to receive(:get).with("session-1").and_return(
      status: :running,
      agent: agent
    )

    expect(history).not_to receive(:truncate_from_created_at)
    expect(server).not_to receive(:handle_user_message)

    server.send(:handle_edit_message, "session-1", "edited", "123.0")
  end

  it "keeps the existing edit flow for an idle session" do
    allow(registry).to receive(:get).with("session-1").and_return(
      status: :idle,
      agent: agent
    )
    allow(history).to receive(:respond_to?).with(:truncate_from_created_at).and_return(true)

    expect(history).to receive(:truncate_from_created_at).with("123.0")
    expect(server).to receive(:handle_user_message).with("session-1", "edited")

    server.send(:handle_edit_message, "session-1", "edited", "123.0")
  end
end
