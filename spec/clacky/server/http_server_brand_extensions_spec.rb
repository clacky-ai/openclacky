# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"
require "clacky/brand_config"

RSpec.describe Clacky::Server::HttpServer, "GET /api/store/extensions/brand" do
  let(:server) { described_class.allocate }
  let(:response) { double("response").as_null_object }
  let(:brand) { instance_double(Clacky::BrandConfig, activated?: true) }

  before do
    allow(Clacky::BrandConfig).to receive(:load).and_return(brand)
    allow(server).to receive(:installed_extension_containers).and_return({})
  end

  it "forwards a supported sort order to the brand catalog" do
    request = instance_double(WEBrick::HTTPRequest, query: { "sort" => "updated" })
    expect(brand).to receive(:fetch_brand_extensions!)
      .with(sort: "updated")
      .and_return(success: true, extensions: [])

    server.send(:api_store_extensions_brand, request, response)
  end

  it "falls back to downloads for an unsupported sort order" do
    request = instance_double(WEBrick::HTTPRequest, query: { "sort" => "unexpected" })
    expect(brand).to receive(:fetch_brand_extensions!)
      .with(sort: "downloads")
      .and_return(success: true, extensions: [])

    server.send(:api_store_extensions_brand, request, response)
  end
end
