# frozen_string_literal: true

require "spec_helper"
require "clacky/platform_http_client"

RSpec.describe Clacky::PlatformHttpClient, "explicit platform host" do
  around do |example|
    ClimateControl.modify("CLACKY_LICENSE_SERVER" => nil) { example.run }
  end

  it "normalizes and uses only the explicit enterprise origin" do
    client = described_class.new(host: "HTTPS://Enterprise.EXAMPLE.com:443/")

    expect(client).to receive(:execute_request)
      .with(:post, "https://enterprise.example.com", "/api/v1/device/authorize", {}, {},
            read_timeout_override: nil)
      .and_return(success: true, data: {})

    expect(client.post("/api/v1/device/authorize", {})).to include(success: true)
  end

  it "does not fall back to official hosts after an explicit host fails" do
    client = described_class.new(host: "https://enterprise.example.com")

    expect(client).to receive(:execute_request).once
      .with(:post, "https://enterprise.example.com", "/api/v1/device/authorize", {}, {},
            read_timeout_override: nil)
      .and_raise(described_class::RetryableNetworkError, "offline")

    expect(client).to receive(:sleep).once
    expect(client.post("/api/v1/device/authorize", {})).to include(
      success: false,
      error: a_string_including("offline")
    )
  end

  it "rejects an explicit URL that is not an HTTP origin" do
    expect {
      described_class.new(host: "https://enterprise.example.com/admin?token=secret")
    }.to raise_error(ArgumentError, /HTTP\/HTTPS origin/)
  end

  it "keeps the existing environment override behavior when no host is supplied" do
    ClimateControl.modify("CLACKY_LICENSE_SERVER" => "https://wrapper.example.com") do
      client = described_class.new

      expect(client).to receive(:execute_request)
        .with(:get, "https://wrapper.example.com", "/api/v1/health", nil, {},
              read_timeout_override: nil)
        .and_return(success: true, data: {})

      expect(client.get("/api/v1/health")).to include(success: true)
    end
  end
end
