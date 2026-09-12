# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "enterprise license status" do
  let(:server) { described_class.allocate }
  let(:source) { "https://enterprise.example.com" }
  let(:identity) { Clacky::Identity.new("device_token" => "device-secret", "platform_source" => source) }
  let(:response) { double("response").as_null_object }

  before do
    allow(server).to receive(:effective_clacky_license_server).and_return(source)
    allow(Clacky::Identity).to receive(:load).and_return(identity)
  end

  it "never sends credentials to a changed platform source" do
    allow(server).to receive(:effective_clacky_license_server).and_return("https://other.example.com")
    expect(Clacky::PlatformHttpClient).not_to receive(:new)
    expect(server).to receive(:json_response).with(response, 200, { bound: false })
    server.send(:api_enterprise_license, response)
  end

  it "returns a verified license without exposing the device credential" do
    client = instance_double(Clacky::PlatformHttpClient)
    allow(Clacky::PlatformHttpClient).to receive(:new).with(host: source).and_return(client)
    expect(client).to receive(:get).with("/api/v1/device/license", headers: { "Authorization" => "Bearer device-secret" })
      .and_return(success: true, data: { "active" => true, "product_name" => "Enterprise", "device_limit" => 2, "devices_used" => 1 })
    expect(server).to receive(:json_response).with(response, 200, hash_including(bound: true, active: true, product_name: "Enterprise"))
    server.send(:api_enterprise_license, response)
  end

  it "shows unknown rather than active when the server is unavailable" do
    client = instance_double(Clacky::PlatformHttpClient)
    allow(Clacky::PlatformHttpClient).to receive(:new).and_return(client)
    allow(client).to receive(:get).and_return(success: false, error: "unavailable")
    expect(server).to receive(:json_response).with(response, 200, { bound: true, active: false, reason: "unreachable" })
    server.send(:api_enterprise_license, response)
  end

  it "does not ask an already licensed enterprise device to activate a serial number" do
    allow(server).to receive(:enterprise_license_status).and_return(bound: true, active: true, product_name: "Enterprise")
    allow(Clacky::BrandConfig).to receive(:load).and_return(Clacky::BrandConfig.new("product_name" => "Enterprise"))
    expect(server).to receive(:json_response).with(
      response,
      200,
      hash_including(needs_activation: false, enterprise_licensed: true, user_licensed: false, license_user_id: nil)
    )
    server.send(:api_brand_status, response)
  end

  it "keeps a bound but unavailable enterprise device out of the serial-number flow" do
    allow(server).to receive(:enterprise_license_status).and_return(bound: true, active: false, reason: "unreachable")
    allow(Clacky::BrandConfig).to receive(:load).and_return(Clacky::BrandConfig.new("product_name" => "Enterprise"))
    expect(server).to receive(:json_response).with(
      response,
      200,
      hash_including(needs_activation: false, enterprise_licensed: false, user_licensed: false)
    )
    server.send(:api_brand_status, response)
  end

  it "refreshes enterprise branding after a platform switch cleared the old brand" do
    brand = instance_double(
      Clacky::BrandConfig,
      branded?: false,
      product_name: nil,
      distribution_refresh_due?: true
    )
    allow(server).to receive(:enterprise_license_status).and_return(bound: true, active: true, product_name: "Enterprise")
    allow(Clacky::BrandConfig).to receive(:load).and_return(brand)
    expect(server).to receive(:trigger_async_distribution_refresh!).once
    expect(server).to receive(:json_response).with(
      response,
      200,
      hash_including(distribution_refresh_pending: true, enterprise_licensed: true)
    )
    server.send(:api_brand_status, response)
  end
end
