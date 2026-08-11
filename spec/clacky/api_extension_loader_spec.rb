# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ApiExtensionLoader do
  let(:tmp) { Dir.mktmpdir }

  before { Clacky::ApiExtension.reset_registry! }
  after  { FileUtils.remove_entry(tmp) }

  def make_container(id, handler_rb:, ext_yml_extra: "")
    dir = File.join(tmp, id)
    FileUtils.mkdir_p(File.join(dir, "api"))
    File.write(File.join(dir, "api/handler.rb"), handler_rb)
    File.write(File.join(dir, "ext.yml"), <<~YAML)
      id: #{id}
      name: #{id}
      version: "0.0.1"
      origin: self
      contributes:
        api: api/handler.rb
      #{ext_yml_extra}
    YAML
    dir
  end

  def load_from_layer
    Clacky::ExtensionLoader.invalidate_cache!
    allow(Clacky::ExtensionLoader).to receive(:load_all).and_wrap_original do |m, **kwargs|
      m.call(**kwargs.merge(layers: { local: tmp }, force: true))
    end
    described_class.load_all
  end

  describe ".load_all" do
    it "loads a valid extension and registers it under its ext id" do
      make_container("my-dashboard", handler_rb: <<~RUBY)
        class MyDashboardLoaderTestExt < Clacky::ApiExtension
          get "/summary" do
            json(ok: true)
          end
        end
      RUBY

      result = load_from_layer

      expect(result.loaded).to eq(["my-dashboard"])
      expect(result.skipped).to be_empty
      klass = Clacky::ApiExtension.registry["my-dashboard"]
      expect(klass).not_to be_nil
      expect(klass.ext_id).to eq("my-dashboard")
      expect(klass.routes.size).to eq(1)
    end

    it "skips an extension whose handler.rb has a syntax error without aborting others" do
      make_container("good", handler_rb: <<~RUBY)
        class GoodLoaderTestExt < Clacky::ApiExtension
          get "/x" do
            json(ok: true)
          end
        end
      RUBY

      make_container("broken", handler_rb: "class Broken < Clacky::ApiExtension\n  get '/x' do  # missing end\n")

      result = load_from_layer

      expect(result.loaded).to include("good")
      expect(result.skipped.map(&:first)).to include("broken")
    end

    it "skips an extension that does not define a Clacky::ApiExtension subclass" do
      make_container("empty", handler_rb: "puts 'no class here'\n")
      result = load_from_layer
      expect(result.skipped.map(&:first)).to include("empty")
    end

    it "skips an extension that declares no routes" do
      make_container("no-routes", handler_rb: <<~RUBY)
        class NoRoutesLoaderTestExt < Clacky::ApiExtension
        end
      RUBY
      result = load_from_layer
      expect(result.skipped.map(&:first)).to include("no-routes")
    end

    it "skips an extension that uses public_endpoint without ext.yml top-level public:true" do
      make_container("webhook", handler_rb: <<~RUBY)
        class WebhookLoaderTestExt < Clacky::ApiExtension
          public_endpoint "/in"
          post "/in" do
            json(ok: true)
          end
        end
      RUBY
      result = load_from_layer
      reasons = result.skipped.to_h
      expect(reasons["webhook"]).to match(/public_endpoint/)
    end

    it "accepts public_endpoint when ext.yml declares public: true at the top level" do
      make_container("webhook2", ext_yml_extra: "public: true\n", handler_rb: <<~RUBY)
        class Webhook2LoaderTestExt < Clacky::ApiExtension
          public_endpoint "/in"
          post "/in" do
            json(ok: true)
          end
        end
      RUBY
      result = load_from_layer
      expect(result.loaded).to include("webhook2")
    end

    it "isolates two extensions that define the same class and constant names" do
      shared_handler = lambda do |route|
        <<~RUBY
          module SharedHelper
            LIMIT = #{route}
          end

          class CollidingExt < Clacky::ApiExtension
            get "/#{route}" do
              json(limit: SharedHelper::LIMIT)
            end
          end
        RUBY
      end

      make_container("twin-a", handler_rb: shared_handler.call(1))
      make_container("twin-b", handler_rb: shared_handler.call(2))

      result = load_from_layer

      expect(result.skipped).to be_empty
      expect(result.loaded).to include("twin-a", "twin-b")

      a = Clacky::ApiExtension.registry["twin-a"]
      b = Clacky::ApiExtension.registry["twin-b"]
      expect(a).not_to equal(b)
      expect(a.routes.size).to eq(1)
      expect(b.routes.size).to eq(1)
      expect(a.ext_id).to eq("twin-a")
      expect(b.ext_id).to eq("twin-b")
      expect(Object.const_defined?(:CollidingExt)).to be(false)
      expect(Object.const_defined?(:SharedHelper)).to be(false)
    end

    it "keeps each colliding extension's constants bound to its own copy at request time" do
      handler = lambda do |limit|
        <<~RUBY
          module TwinLimits
            LIMIT = #{limit}
          end

          class TwinRuntimeExt < Clacky::ApiExtension
            get "/limit" do
              json(limit: TwinLimits::LIMIT)
            end
          end
        RUBY
      end

      make_container("rt-a", handler_rb: handler.call(11))
      make_container("rt-b", handler_rb: handler.call(22))
      load_from_layer

      limits = %w[rt-a rt-b].map do |id|
        klass = Clacky::ApiExtension.registry[id]
        route = klass.routes.first
        inst = klass.new(req: nil, res: nil, route: route, params: {}, http_server: nil)
        begin
          inst.invoke
          nil
        rescue Clacky::ApiExtension::Halt => e
          JSON.parse(e.payload)["limit"]
        end
      end

      expect(limits).to eq([11, 22])
    end
  end
end
