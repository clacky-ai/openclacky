# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "GET /api/store/extensions/local" do
  let(:server) { described_class.allocate }
  let(:response) { double("response").as_null_object }
  let(:dir) { Dir.mktmpdir("clacky-local-ext-spec") }

  before do
    @payload = nil
    allow(server).to receive(:json_response) { |_res, _code, body| @payload = body }
  end

  after { FileUtils.remove_entry(dir) if File.directory?(dir) }

  def container(ext_id, layer: :local, name: nil, version: "1.0.0", raw: {}, disabled: false, mtime: Time.now)
    ext_dir = File.join(dir, ext_id)
    FileUtils.mkdir_p(ext_dir)
    File.write(File.join(ext_dir, "ext.yml"), "name: #{name || ext_id}\n")
    File.utime(mtime, mtime, File.join(ext_dir, "ext.yml"))
    {
      ext_id:   ext_id,
      layer:    layer,
      dir:      ext_dir,
      name:     name || ext_id,
      version:  version,
      author:   "leo",
      homepage: "",
      origin:   "self",
      contributes: {},
      raw:      raw,
      disabled: disabled,
    }
  end

  def stub_containers(containers)
    allow(Clacky::ExtensionLoader).to receive(:load_all)
      .and_return(Clacky::ExtensionLoader::Result.new(containers: containers))
  end

  def extensions
    @payload[:extensions]
  end

  it "lists only the local layer, most recently edited first" do
    stub_containers(
      "clock"     => container("clock", mtime: Time.now - 3600),
      "expert-team" => container("expert-team", mtime: Time.now),
      "knowledge" => container("knowledge", layer: :builtin),
      "ppt-assistant" => container("ppt-assistant", layer: :installed)
    )

    server.send(:api_store_extensions_local, response)

    expect(extensions.map { |e| e["id"] }).to eq(%w[expert-team clock])
    expect(extensions.map { |e| e["layer"] }.uniq).to eq(%w[local])
  end

  it "describes a local extension from its own manifest" do
    stub_containers(
      "clock" => container(
        "clock",
        name: "Clock",
        version: "0.2.1",
        raw: {
          "display_name"    => "Clock",
          "display_name_zh" => "时钟",
          "description"     => "A tiny clock panel",
          "description_zh"  => "一个小小时钟面板",
        }
      )
    )

    server.send(:api_store_extensions_local, response)

    ext = extensions.first
    expect(ext["name"]).to eq("Clock")
    expect(ext["display_name"]).to eq("Clock")
    expect(ext["display_name_zh"]).to eq("时钟")
    expect(ext["description"]).to eq("A tiny clock panel")
    expect(ext["description_zh"]).to eq("一个小小时钟面板")
    expect(ext["version"]).to eq("0.2.1")
    expect(ext["origin"]).to eq("self")
    expect(ext["installed"]).to be(true)
    expect(ext["disabled"]).to be(false)
  end

  it "keeps switched-off extensions in the list so they can be turned back on" do
    stub_containers("clock" => container("clock", disabled: true))

    server.send(:api_store_extensions_local, response)

    expect(extensions.map { |e| e["id"] }).to eq(%w[clock])
    expect(extensions.first["disabled"]).to be(true)
  end

  it "returns an empty list when nothing is developed locally" do
    stub_containers({})

    server.send(:api_store_extensions_local, response)

    expect(extensions).to eq([])
  end
end
