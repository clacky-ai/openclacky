# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ExtStudioExt API handler" do
  let(:ext_dir) { Dir.mktmpdir }
  let(:manifest_path) { File.join(ext_dir, "ext.yml") }
  let(:loader_result) { double("loader result", containers: { "demo" => { dir: ext_dir } }) }
  let(:handler_class) do
    Clacky::ApiExtension.reset_registry!
    handler_path = File.expand_path("../../lib/clacky/default_extensions/ext-studio/api/handler.rb", __dir__)
    load(handler_path, true)
    Clacky::ApiExtension.pending_subclasses.last
  end
  let(:route) do
    handler_class.routes.find do |candidate|
      candidate.method == :post && candidate.pattern == "/set_version"
    end
  end

  before do
    File.write(manifest_path, "id: demo\nversion: 1.0.0\ncontributes: {}\n")
    allow(Clacky::ExtensionLoader).to receive(:load_all).and_return(loader_result)
  end

  after do
    FileUtils.remove_entry(ext_dir) if Dir.exist?(ext_dir)
    Clacky::ApiExtension.reset_registry!
  end

  def invoke_set_version(version)
    req = double("request", body: JSON.generate(ext_id: "demo", version: version))
    instance = handler_class.new(req: req, res: nil, route: route, params: {}, http_server: nil)
    instance.invoke
  end

  it "writes a valid three-segment numeric version" do
    expect { invoke_set_version("10.2.35") }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(200)
      expect(JSON.parse(halt.payload)).to include("version" => "10.2.35")
    end

    expect(File.read(manifest_path)).to include("version: 10.2.35")
  end

  it "rejects an invalid version without changing ext.yml" do
    original = File.read(manifest_path)

    ["测试test", "1.0", "1..0", "1.0.0.1"].each do |version|
      expect { invoke_set_version(version) }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
        expect(halt.status).to eq(422)
        expect(JSON.parse(halt.payload)["error"]).to match(/1\.0\.0/)
      end
    end

    expect(File.read(manifest_path)).to eq(original)
  end
end
