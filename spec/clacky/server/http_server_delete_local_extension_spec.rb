# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "POST /api/store/extension/delete-local" do
  let(:server) { described_class.allocate }
  let(:response) { double("response").as_null_object }
  let(:root) { Dir.mktmpdir("clacky-local-ext-del") }
  let(:dir) { File.join(root, "clock") }

  before do
    @payload = nil
    @code    = nil
    allow(server).to receive(:json_response) { |_res, code, body| @code = code; @payload = body }
    allow(server).to receive(:parse_json_body).and_return({ "id" => "clock" })
    stub_const("Clacky::ExtensionLoader::LOCAL_DIR", root)
    allow(Clacky::ExtensionLoader).to receive(:invalidate_cache!)
    allow(Clacky::ApiExtensionLoader).to receive(:load_all)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "ext.yml"), "name: Clock\n")
  end

  after { FileUtils.remove_entry(root) if File.directory?(root) }

  def container(ext_id, layer: :local, path: nil)
    {
      ext_id: ext_id,
      layer:  layer,
      dir:    path || File.join(root, ext_id),
      name:   ext_id,
      version: "1.0.0",
    }
  end

  def stub_containers(containers)
    allow(Clacky::ExtensionLoader).to receive(:load_all)
      .and_return(Clacky::ExtensionLoader::Result.new(containers: containers))
  end

  it "removes the working copy and reloads the extension registries" do
    stub_containers("clock" => container("clock"))

    server.send(:api_store_extension_delete_local, double("req"), response)

    expect(@code).to eq(200)
    expect(@payload[:ok]).to be(true)
    expect(Dir.exist?(dir)).to be(false)
    expect(Clacky::ExtensionLoader).to have_received(:invalidate_cache!)
    expect(Clacky::ApiExtensionLoader).to have_received(:load_all)
  end

  it "refuses a marketplace install, which has its own uninstall route" do
    stub_containers("clock" => container("clock", layer: :installed))

    server.send(:api_store_extension_delete_local, double("req"), response)

    expect(@code).to eq(422)
    expect(@payload[:ok]).to be(false)
    expect(Dir.exist?(dir)).to be(true)
  end

  it "answers 404 for an unknown id" do
    stub_containers({})

    server.send(:api_store_extension_delete_local, double("req"), response)

    expect(@code).to eq(404)
    expect(@payload[:ok]).to be(false)
  end

  it "never deletes a directory outside the local layer root" do
    outside = Dir.mktmpdir("clacky-outside")
    begin
      stub_containers("clock" => container("clock", path: outside))

      server.send(:api_store_extension_delete_local, double("req"), response)

      expect(@code).to eq(422)
      expect(Dir.exist?(outside)).to be(true)
    ensure
      FileUtils.remove_entry(outside) if File.directory?(outside)
    end
  end
end
