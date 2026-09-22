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

  # Uninstall/enable address an extension by the directory it was installed
  # under. The catalog's own `id` is a remote row id, so the response has to
  # carry the slug too or every row action answers "Not installed".
  it "tags each catalog entry with the slug local actions address it by" do
    request = instance_double(WEBrick::HTTPRequest, query: {})
    allow(brand).to receive(:fetch_brand_extensions!)
      .and_return(success: true, extensions: [{ "id" => 178, "name" => "pptx-pro" }])

    captured = nil
    allow(response).to receive(:body=) { |json| captured = JSON.parse(json) }

    server.send(:api_store_extensions_brand, request, response)

    row = captured["extensions"].first
    expect(row["slug"]).to eq("pptx-pro")
    expect(row["id"]).to eq(178)
  end
end

RSpec.describe Clacky::Server::HttpServer, "GET /api/store/extensions" do
  let(:server) { described_class.allocate }
  let(:response) { double("response").as_null_object }
  let(:brand) { instance_double(Clacky::BrandConfig) }

  before do
    allow(Clacky::BrandConfig).to receive(:load).and_return(brand)
    allow(server).to receive(:installed_extension_containers).and_return({})
  end

  it "carries the installed slug next to the store's own row id" do
    request = instance_double(WEBrick::HTTPRequest, query: {})
    allow(brand).to receive(:search_extensions!)
      .and_return(success: true, extensions: [{ "id" => 178, "name" => "wsl-picker-utf8-fix" }], meta: {})

    captured = nil
    allow(response).to receive(:body=) { |json| captured = JSON.parse(json) }

    server.send(:api_store_extensions, request, response)

    row = captured["extensions"].first
    expect(row["slug"]).to eq("wsl-picker-utf8-fix")
    expect(row["id"]).to eq(178)
    expect(row["installed"]).to be(false)
  end
end
