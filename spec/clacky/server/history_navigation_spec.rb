# frozen_string_literal: true

require "clacky/server/http_server"

RSpec.describe "Session history navigation API" do
  let(:server) { Clacky::Server::HttpServer.allocate }
  let(:agent) do
    Class.new do
      include Clacky::Agent::SessionSerializer
      def initialize
        @history = Clacky::MessageHistory.new([
          { role: "user", content: "First", created_at: 10 },
          { role: "assistant", content: "Answer" },
          { role: "user", content: "Second", created_at: 20 }
        ])
      end
    end.new
  end

  before do
    registry = double("registry", ensure: true)
    allow(registry).to receive(:with_session).with("test").and_yield({ agent: agent })
    server.instance_variable_set(:@registry, registry)
    allow(server).to receive(:json_response) { |_res, status, body| { status: status, body: body } }
  end

  def request(query)
    server.send(:api_session_messages, "test", double(query_string: URI.encode_www_form(query)), Object.new)
  end

  def first_id
    source = request(navigation: 1)[:body][:sources].first
    JSON.generate([source[:key], 0, source[:version], source[:identities].first])
  end

  it "returns counts and identities without replaying or previewing message bodies" do
    expect(agent).not_to receive(:replay_history)
    expect(agent).not_to receive(:navigation_entry)
    response = request(navigation: 1)
    expect(response[:status]).to eq(200)
    expect(response[:body][:total]).to eq(2)
    expect(JSON.generate(response[:body])).not_to include("First", "Answer")
    expect(response[:body]).not_to have_key(:events)
  end

  it "returns just the requested preview" do
    response = request(preview: first_id)
    expect(response[:status]).to eq(200)
    expect(response[:body]).to include(user: "First", assistant: "Answer")
    expect(response[:body]).not_to have_key(:events)
  end

  it "returns a bounded batch of previews in request order" do
    manifest = request(navigation: 1)[:body][:sources].first
    ids = 2.times.map do |offset|
      JSON.generate([manifest[:key], offset, manifest[:version], manifest[:identities][offset]])
    end
    response = request(previews: JSON.generate(ids))
    expect(response[:status]).to eq(200)
    expect(response[:body][:previews].map { |entry| entry[:user] }).to eq(["First", "Second"])
    expect(response[:body]).not_to have_key(:events)
  end

  it "rejects malformed or oversized preview batches" do
    expect(request(previews: "not-json")[:status]).to eq(409)
    expect(request(previews: JSON.generate([first_id] * 31))[:status]).to eq(409)
  end

  it "stamps source IDs onto user events and provides both pagination directions" do
    id = first_id
    response = request(window: 1, around: id, limit: 1)
    expect(response[:body]).to include(has_more: false, has_after: true, before_cursor: id, after_cursor: id)
    expect(response[:body][:events].first).to include(type: "history_user_message", round_id: id, content: "First")
  end

  it "rejects a stale or malformed location without returning a different page" do
    response = request(window: 1, around: "bad-location")
    expect(response[:status]).to eq(409)
    expect(response[:body]).to have_key(:error)
    expect(response[:body]).not_to have_key(:events)
    expect(request(preview: "bad-location")[:status]).to eq(409)
  end

  it "preserves the existing timestamp-based API for other callers" do
    response = request(before: 20, limit: 1)
    expect(response[:status]).to eq(200)
    expect(response[:body][:events].first[:content]).to eq("First")
  end

  it "does not mistake an unavailable agent for an empty preview" do
    registry = server.instance_variable_get(:@registry)
    allow(registry).to receive(:with_session).with("test").and_yield({ agent: nil })
    expect(request(navigation: 1)[:body]).to eq(sources: [], total: 0)
    expect(request(preview: "old-location")[:status]).to eq(409)
  end
end
