# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "clacky/mcp/connection_manager"

RSpec.describe Clacky::Mcp::ConnectionManager do
  let(:home) { Dir.mktmpdir }
  let(:session) { instance_double(Clacky::Mcp::OAuth::Session) }

  after { FileUtils.rm_rf(home) }

  def write_config(spec)
    directory = File.join(home, ".clacky")
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "mcp.json"), JSON.generate("mcpServers" => { "remote" => spec }))
  end

  it "logs in an OAuth server and returns only safe status" do
    write_config("url" => "https://example.com/mcp", "auth" => { "type" => "oauth" })
    allow(session).to receive(:login).and_return("access_token" => "do-not-leak")
    allow(session).to receive(:status).and_return("connected" => true, "expires_at" => 1_900_000_000)
    manager = described_class.new(server_name: "remote", home: home, session_factory: ->(*_args) { session })

    result = manager.login

    expect(result).to include("server" => "remote", "connected" => true)
    expect(JSON.generate(result)).not_to include("do-not-leak")
  end

  it "rejects an unknown server" do
    manager = described_class.new(server_name: "missing", home: home)

    expect { manager.status }.to raise_error(described_class::Error, /not configured/)
  end

  it "rejects a server without OAuth configuration" do
    write_config("url" => "https://example.com/mcp")
    manager = described_class.new(server_name: "remote", home: home)

    expect { manager.login }.to raise_error(described_class::Error, /not configured for OAuth/)
  end

  it "logs out through the session" do
    write_config("url" => "https://example.com/mcp", "auth" => { "type" => "oauth" })
    allow(session).to receive(:logout).and_return(true)
    manager = described_class.new(server_name: "remote", home: home, session_factory: ->(*_args) { session })

    expect(manager.logout).to eq("server" => "remote", "connected" => false)
  end
end
