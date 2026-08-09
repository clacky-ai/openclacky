# frozen_string_literal: true

require "spec_helper"
require "clacky/mcp/oauth/config"

RSpec.describe Clacky::Mcp::OAuth::Config do
  it "is disabled when auth is absent" do
    config = described_class.from_server_spec("url" => "https://example.com/mcp")

    expect(config).not_to be_enabled
    expect(config.resource).to eq("https://example.com/mcp")
  end

  it "defaults an OAuth resource to the MCP URL" do
    config = described_class.from_server_spec(
      "url" => "https://example.com/mcp",
      "auth" => { "type" => "oauth" }
    )

    expect(config).to be_enabled
    expect(config.resource).to eq("https://example.com/mcp")
  end

  it "accepts an explicit HTTPS resource" do
    config = described_class.from_server_spec(
      "url" => "https://gateway.example.com/mcp",
      "auth" => { "type" => "oauth", "resource" => "https://resource.example.com/mcp" }
    )

    expect(config.resource).to eq("https://resource.example.com/mcp")
  end

  it "rejects OAuth for an insecure remote resource" do
    expect do
      described_class.from_server_spec(
        "url" => "http://example.com/mcp",
        "auth" => { "type" => "oauth" }
      )
    end.to raise_error(Clacky::Mcp::OAuth::Config::Error, /HTTPS/)
  end

  it "rejects an insecure MCP endpoint even when the resource is HTTPS" do
    expect do
      described_class.from_server_spec(
        "url" => "http://example.com/mcp",
        "auth" => { "type" => "oauth", "resource" => "https://example.com/mcp" }
      )
    end.to raise_error(Clacky::Mcp::OAuth::Config::Error, /endpoint.*HTTPS/i)
  end

  it "rejects unknown authentication types" do
    expect do
      described_class.from_server_spec(
        "url" => "https://example.com/mcp",
        "auth" => { "type" => "magic" }
      )
    end.to raise_error(Clacky::Mcp::OAuth::Config::Error, /unsupported/)
  end
end
