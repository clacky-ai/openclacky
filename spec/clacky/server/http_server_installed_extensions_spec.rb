# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "GET /api/store/extensions/installed" do
  let(:server) { described_class.allocate }
  let(:response) { double("response").as_null_object }

  before do
    @payload = nil
    allow(server).to receive(:json_response) { |_res, _code, body| @payload = body }
  end

  def container(layer:, name: "dummy", version: "1.0.0", raw: {}, disabled: false, **rest)
    {
      layer:   layer,
      name:    name,
      version: version,
      raw:     raw,
      author:  "OpenClacky",
      homepage: "",
      origin:  "marketplace",
      disabled: disabled,
    }.merge(rest)
  end

  def stub_containers(containers)
    allow(Clacky::ExtensionLoader).to receive(:load_all)
      .and_return(Clacky::ExtensionLoader::Result.new(containers: containers))
  end

  def stub_market(mapping)
    allow(server).to receive(:fetch_batch_market_data).and_return(mapping)
  end

  def extensions
    @payload[:extensions]
  end

  it "lists the builtin and installed layers, builtin first, and skips local copies" do
    stub_containers(
      "orchestrator" => container(layer: :installed, name: "orchestrator"),
      "computer-use" => container(layer: :builtin, name: "Computer Use"),
      "task-board"   => container(layer: :local, name: "task-board")
    )
    stub_market({})

    server.send(:api_store_extensions_installed, response)

    expect(extensions.map { |e| e["id"] }).to eq(%w[computer-use orchestrator])
    expect(extensions.map { |e| e["layer"] }).to eq(%w[builtin installed])
  end

  it "keeps extensions that own a dedicated surface out of the list" do
    stub_containers(
      "coding"    => container(layer: :builtin, name: "Coding"),
      "preview"   => container(layer: :builtin, name: "Preview"),
      "ext-studio" => container(layer: :builtin, name: "Ext Studio")
    )
    stub_market({})

    server.send(:api_store_extensions_installed, response)

    expect(extensions.map { |e| e["id"] }).to eq(%w[preview])
  end

  it "describes a builtin from its own manifest and never marks it unlisted" do
    stub_containers(
      "computer-use" => container(
        layer: :builtin,
        name: "Computer Use",
        disabled: true,
        raw: {
          "display_name"    => "Computer Use",
          "display_name_zh" => "电脑操作",
          "description"     => "Drive the macOS desktop",
        }
      )
    )
    stub_market({})

    server.send(:api_store_extensions_installed, response)

    ext = extensions.first
    expect(ext["display_name_zh"]).to eq("电脑操作")
    expect(ext["description"]).to eq("Drive the macOS desktop")
    expect(ext["unlisted"]).to be(false)
    expect(ext["disabled"]).to be(true)
    expect(ext["removable"]).to be(false)
  end

  it "prefers marketplace metadata for an installed extension and allows removing it" do
    stub_containers("orchestrator" => container(layer: :installed, name: "orchestrator", version: "1.0.0"))
    stub_market("orchestrator" => {
      "name" => "Orchestrator", "display_name" => "Orchestrator", "description" => "Runs multi-agent jobs",
      "version" => "1.2.0", "author" => "windy", "icon_url" => "https://cdn.example/i.png",
      "origin" => "marketplace", "download_count" => 42,
    })

    server.send(:api_store_extensions_installed, response)

    ext = extensions.first
    expect(ext["name"]).to eq("Orchestrator")
    expect(ext["version"]).to eq("1.2.0")
    expect(ext["installed_version"]).to eq("1.0.0")
    expect(ext["icon_url"]).to eq("https://cdn.example/i.png")
    expect(ext["download_count"]).to eq(42)
    expect(ext["unlisted"]).to be(false)
    expect(ext["removable"]).to be(true)
  end

  it "flags an installed extension the marketplace no longer knows as unlisted" do
    stub_containers("session-messenger" => container(layer: :installed, name: "session-messenger"))
    stub_market({})

    server.send(:api_store_extensions_installed, response)

    ext = extensions.first
    expect(ext["name"]).to eq("session-messenger")
    expect(ext["unlisted"]).to be(true)
    expect(ext["removable"]).to be(true)
  end
end
