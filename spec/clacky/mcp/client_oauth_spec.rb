# frozen_string_literal: true

require "spec_helper"
require "clacky/mcp/client"
require "clacky/mcp/oauth/session"

RSpec.describe Clacky::Mcp::Client do
  it "builds an OAuth session for an authenticated HTTP server" do
    client = described_class.from_spec("remote", {
      "type" => "http",
      "url" => "https://example.com/mcp",
      "auth" => { "type" => "oauth" }
    })

    transport = client.instance_variable_get(:@transport)
    expect(transport.instance_variable_get(:@authorization)).to be_a(Clacky::Mcp::OAuth::Session)
  end

  it "keeps static-header HTTP servers unauthenticated" do
    client = described_class.from_spec("remote", {
      "type" => "http",
      "url" => "https://example.com/mcp",
      "headers" => { "Authorization" => "Bearer static" }
    })

    transport = client.instance_variable_get(:@transport)
    expect(transport.instance_variable_get(:@authorization)).to be_nil
  end
end
