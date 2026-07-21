# frozen_string_literal: true

require "spec_helper"

RSpec.describe "extension data persistence outside package" do
  let(:root)      { Dir.mktmpdir }
  let(:installed) { File.join(root, "installed") }
  let(:data_dir)  { File.join(root, "ext-data") }

  before do
    FileUtils.mkdir_p(installed)
    stub_const("Clacky::ExtensionLoader::INSTALLED_DIR", installed)
    stub_const("Clacky::ExtensionLoader::DATA_DIR", data_dir)
    Clacky::ExtensionLoader.invalidate_cache!
  end

  after { FileUtils.remove_entry(root) if Dir.exist?(root) }

  describe "Clacky::ExtensionLoader.data_dir_for" do
    it "resolves under the package-external data root" do
      expect(Clacky::ExtensionLoader.data_dir_for("acme"))
        .to eq(File.join(data_dir, "acme"))
    end
  end

  describe "Clacky::ExtensionLoader.uninstall!" do
    def install_stub(id)
      pkg = File.join(installed, id)
      FileUtils.mkdir_p(pkg)
      File.write(File.join(pkg, "ext.yml"), "id: #{id}\norigin: self\n")
      pkg
    end

    it "keeps the external data dir by default so a reinstall reconnects" do
      install_stub("acme")
      FileUtils.mkdir_p(Clacky::ExtensionLoader.data_dir_for("acme"))
      File.write(File.join(data_dir, "acme", "teams.json"), "[1,2]")

      expect(Clacky::ExtensionLoader.uninstall!("acme")).to be(true)

      expect(Dir.exist?(File.join(installed, "acme"))).to be(false)
      expect(File.read(File.join(data_dir, "acme", "teams.json"))).to eq("[1,2]")
    end

    it "deletes the external data dir when purge_data is true" do
      install_stub("acme")
      FileUtils.mkdir_p(Clacky::ExtensionLoader.data_dir_for("acme"))
      File.write(File.join(data_dir, "acme", "teams.json"), "[1,2]")

      expect(Clacky::ExtensionLoader.uninstall!("acme", purge_data: true)).to be(true)

      expect(Dir.exist?(File.join(data_dir, "acme"))).to be(false)
    end

    it "returns false when the extension is not installed" do
      expect(Clacky::ExtensionLoader.uninstall!("ghost")).to be(false)
    end
  end

  describe "Clacky::ApiExtension#data_path" do
    def handler_instance(ext_id:, ext_dir:)
      klass = Class.new(Clacky::ApiExtension)
      klass.ext_id  = ext_id
      klass.ext_dir = ext_dir
      klass.allocate.tap do |obj|
        obj.instance_variable_set(:@http_server, nil)
      end
    end

    it "returns a path under the package-external data dir" do
      obj = handler_instance(ext_id: "acme", ext_dir: File.join(installed, "acme"))
      path = obj.data_path("state.json")

      expect(path).to eq(File.join(data_dir, "acme", "state.json"))
      expect(Dir.exist?(File.join(data_dir, "acme"))).to be(true)
    end
  end
end
