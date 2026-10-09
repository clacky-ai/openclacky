# frozen_string_literal: true

require "webrick"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "artifact route" do
  let(:server) { described_class.allocate }
  let(:response) { WEBrick::HTTPResponse.new(WEBrick::Config::HTTP) }
  let(:request) { double("request", :[] => nil) }
  let(:artifact_id) { "c" * 64 }
  let(:store) { instance_double(Clacky::ArtifactStore) }

  before do
    allow(Clacky::ArtifactStore).to receive(:new).and_return(store)
  end

  it "wraps stored HTML with a sandbox-oriented CSP and theme bridge" do
    allow(store).to receive(:read).with(artifact_id).and_return("<button id='go'>Go</button>")

    server.send(:api_serve_artifact, artifact_id, request, response)

    expect(response.status).to eq(200)
    expect(response["Content-Type"]).to eq("text/html; charset=utf-8")
    expect(response["Content-Security-Policy"]).to include("connect-src 'none'")
    expect(response["Content-Security-Policy"]).to include("navigate-to 'none'")
    expect(response["Content-Security-Policy"]).to include("frame-ancestors 'self'")
    expect(response["Referrer-Policy"]).to eq("no-referrer")
    expect(response.body).to include("<button id='go'>Go</button>")
    expect(response.body).to include("clacky:artifact-ready")
    expect(response.body).to include(artifact_id)
  end

  it "returns an immutable 304 response for a matching content hash" do
    etag_request = double("request", :[] => %Q("#{artifact_id}"))
    allow(store).to receive(:read).with(artifact_id).and_return("<p>cached</p>")

    server.send(:api_serve_artifact, artifact_id, etag_request, response)

    expect(response.status).to eq(304)
    expect(response.body).to eq("")
    expect(response["Cache-Control"]).to include("immutable")
  end

  it "returns 404 when the artifact no longer exists" do
    allow(store).to receive(:read).with(artifact_id).and_return(nil)

    server.send(:api_serve_artifact, artifact_id, request, response)

    expect(response.status).to eq(404)
  end
end

RSpec.describe Clacky::Server::HttpServer, "artifact output capabilities" do
  let(:server) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@ws_mutex, Mutex.new)
      instance.instance_variable_set(:@ws_clients, {})
    end
  end

  it "disables artifacts without an active browser subscriber" do
    expect(server.send(:web_output_capabilities_for, "session-1")).to eq([])
  end

  it "enables artifacts for any session with an active browser subscriber" do
    active = double("active_connection", closed?: false)
    server.instance_variable_get(:@ws_clients)["extension-session"] = [active]

    expect(server.send(:web_output_capabilities_for, "extension-session")).to eq([:artifact])
  end

  it "ignores stale closed browser connections" do
    closed = double("closed_connection", closed?: true)
    server.instance_variable_get(:@ws_clients)["session-1"] = [closed]

    expect(server.send(:web_output_capabilities_for, "session-1")).to eq([])
  end
end
