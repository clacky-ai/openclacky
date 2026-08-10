# frozen_string_literal: true

require "spec_helper"
require "json"
require "clacky/mcp/cli_commands"

RSpec.describe Clacky::Mcp::CliCommands do
  let(:manager) do
    instance_double(
      Clacky::Mcp::ConnectionManager,
      login: { "connected" => true, "server" => "chatcut" },
      status: { "connected" => true, "expired" => false, "server" => "chatcut" },
      logout: { "connected" => false, "server" => "chatcut" }
    )
  end

  before do
    allow(Clacky::Mcp::ConnectionManager).to receive(:new).and_return(manager)
  end

  it "reports remote OAuth capability as JSON" do
    expect do
      described_class.start(%w[capabilities --json])
    end.to output(/"remote_oauth":true/).to_stdout
  end

  it "logs in a configured server without printing tokens" do
    expect do
      described_class.start(%w[login chatcut --json])
    end.to output { |text|
      expect(JSON.parse(text)).to include("connected" => true, "server" => "chatcut")
      expect(text).not_to include("access_token", "refresh_token")
    }.to_stdout
    expect(manager).to have_received(:login)
  end

  it "reports connection status without printing tokens" do
    expect do
      described_class.start(%w[status chatcut --json])
    end.to output { |text|
      expect(JSON.parse(text)).to include("connected" => true, "expired" => false)
      expect(text).not_to include("token")
    }.to_stdout
  end

  it "logs out a configured server" do
    expect do
      described_class.start(%w[logout chatcut --json])
    end.to output(/"connected":false/).to_stdout
    expect(manager).to have_received(:logout)
  end
end
