# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ApiExtensionLoader do
  let(:tmp) { Dir.mktmpdir }

  before { Clacky::ApiExtension.reset_registry! }
  after  { FileUtils.remove_entry(tmp) }

  def make_ext(id, handler_rb:, meta: nil)
    dir = File.join(tmp, id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "handler.rb"), handler_rb)
    File.write(File.join(dir, "meta.yml"), meta) if meta
    dir
  end

  describe ".load_all" do
    it "loads a valid extension and registers it under its directory name" do
      make_ext("my-dashboard", handler_rb: <<~RUBY)
        class MyDashboardLoaderTestExt < Clacky::ApiExtension
          get "/summary" do
            json(ok: true)
          end
        end
      RUBY

      result = described_class.load_all(dir: tmp)

      expect(result.loaded).to eq(["my-dashboard"])
      expect(result.skipped).to be_empty
      klass = Clacky::ApiExtension.registry["my-dashboard"]
      expect(klass).not_to be_nil
      expect(klass.ext_id).to eq("my-dashboard")
      expect(klass.routes.size).to eq(1)
    end

    it "skips an extension whose handler.rb has a syntax error without aborting others" do
      make_ext("good", handler_rb: <<~RUBY)
        class GoodLoaderTestExt < Clacky::ApiExtension
          get "/x" do
            json(ok: true)
          end
        end
      RUBY

      make_ext("broken", handler_rb: "class Broken < Clacky::ApiExtension\n  get '/x' do  # missing end\n")

      result = described_class.load_all(dir: tmp)

      expect(result.loaded).to include("good")
      expect(result.skipped.map(&:first)).to include("broken")
    end

    it "skips an extension that does not define a Clacky::ApiExtension subclass" do
      make_ext("empty", handler_rb: "puts 'no class here'\n")
      result = described_class.load_all(dir: tmp)
      expect(result.skipped.map(&:first)).to include("empty")
    end

    it "skips an extension that declares no routes" do
      make_ext("no-routes", handler_rb: <<~RUBY)
        class NoRoutesLoaderTestExt < Clacky::ApiExtension
        end
      RUBY
      result = described_class.load_all(dir: tmp)
      expect(result.skipped.map(&:first)).to include("no-routes")
    end

    it "skips an extension that uses public_endpoint without meta.yml public:true" do
      make_ext("webhook", handler_rb: <<~RUBY)
        class WebhookLoaderTestExt < Clacky::ApiExtension
          public_endpoint "/in"
          post "/in" do
            json(ok: true)
          end
        end
      RUBY
      result = described_class.load_all(dir: tmp)
      reasons = result.skipped.to_h
      expect(reasons["webhook"]).to match(/public_endpoint/)
    end

    it "accepts public_endpoint when meta.yml declares public: true" do
      make_ext("webhook2", meta: "public: true\n", handler_rb: <<~RUBY)
        class Webhook2LoaderTestExt < Clacky::ApiExtension
          public_endpoint "/in"
          post "/in" do
            json(ok: true)
          end
        end
      RUBY
      result = described_class.load_all(dir: tmp)
      expect(result.loaded).to include("webhook2")
    end

    it "skips directories starting with underscore (e.g. _disabled)" do
      make_ext("_disabled/foo", handler_rb: "raise 'should not load'\n")
      result = described_class.load_all(dir: tmp)
      expect(result.loaded).to be_empty
      expect(result.skipped).to be_empty
    end
  end

  describe ".scaffold" do
    it "generates a handler.rb with a sample route" do
      path = described_class.scaffold("test-ext", dir: tmp)
      expect(File.exist?(path)).to be true
      content = File.read(path)
      expect(content).to include("Clacky::ApiExtension")
      expect(content).to include('get "/hello"')
    end

    it "refuses to overwrite an existing extension" do
      described_class.scaffold("dup", dir: tmp)
      expect { described_class.scaffold("dup", dir: tmp) }.to raise_error(ArgumentError, /already exists/)
    end

    it "rejects invalid names" do
      expect { described_class.scaffold("", dir: tmp) }.to raise_error(ArgumentError)
      expect { described_class.scaffold("***", dir: tmp) }.to raise_error(ArgumentError)
    end
  end
end
