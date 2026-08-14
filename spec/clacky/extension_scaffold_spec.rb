# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ExtensionScaffold do
  let(:dir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  describe ".new_container" do
    it "generates a container that the loader resolves with no errors" do
      path = described_class.new_container("hello-panel", dir: dir)

      expect(File).to exist(File.join(path, "ext.yml"))
      expect(File).to exist(File.join(path, "panels/hello/view.js"))
      expect(File).to exist(File.join(path, "api/handler.rb"))
      expect(File).to exist(File.join(path, "test/handler_test.rb"))

      result = Clacky::ExtensionLoader.load_all(layers: { local: dir })
      expect(result.errors).to be_empty
      expect(result.panels.size).to eq(1)
      expect(result.api.size).to eq(1)
    end

    it "slugifies the id" do
      path = described_class.new_container("My Cool Ext!", dir: dir)
      expect(File.basename(path)).to eq("my-cool-ext")
    end

    it "generates a handler that defines an ApiExtension subclass with a route" do
      path = described_class.new_container("ping", dir: dir)
      handler = File.read(File.join(path, "api/handler.rb"))
      expect(handler).to match(/class PingExt < Clacky::ApiExtension/)
      expect(handler).to match(%r{get "/"})
    end

    it "generates a minitest example that loads the handler and asserts the root route" do
      path = described_class.new_container("ping", dir: dir)
      test = File.read(File.join(path, "test/handler_test.rb"))
      expect(test).to match(/require "minitest\/autorun"/)
      expect(test).to match(/require "clacky"/)
      expect(test).to match(/require "json"/)
      expect(test).to match(/load File.expand_path\("\.\.\/api\/handler\.rb", __dir__\)/)
      expect(test).to match(/class PingExtTest < Minitest::Test/)
      expect(test).to match(/Clacky::ApiExtension::Halt/)
      expect(test).to match(/JSON\.parse\(halt\.payload\)\["message"\]/)
      expect(test).not_to match(/def handler_class/)
    end

    it "refuses to overwrite an existing container" do
      described_class.new_container("dup", dir: dir)
      expect { described_class.new_container("dup", dir: dir) }
        .to raise_error(ArgumentError, /already exists/)
    end

    it "rejects an id that slugifies to empty" do
      expect { described_class.new_container("!!!", dir: dir) }
        .to raise_error(ArgumentError, /invalid extension id/)
    end
  end
end
