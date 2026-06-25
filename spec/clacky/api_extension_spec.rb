# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ApiExtension do
  before { described_class.reset_registry! }

  describe "route DSL" do
    it "captures GET routes with a block" do
      klass = Class.new(described_class) do
        get "/items" do
          json(ok: true)
        end
      end
      route = klass.routes.first
      expect(route.method).to eq(:get)
      expect(route.pattern).to eq("/items")
      expect(route.block).to be_a(Proc)
    end

    it "compiles path parameters into a regex with named captures" do
      klass = Class.new(described_class) do
        get "/items/:id" do
          json(id: params[:id])
        end
      end
      route = klass.routes.first
      m = route.regex.match("/items/42")
      expect(m).not_to be_nil
      expect(route.param_names).to eq([:id])
    end

    it "normalizes patterns to a leading slash and no trailing slash" do
      klass = Class.new(described_class) do
        get "things/" do
          json({})
        end
      end
      expect(klass.routes.first.pattern).to eq("/things")
    end

    it "rejects timeouts that are non-positive or exceed MAX_TIMEOUT" do
      expect {
        Class.new(Clacky::ApiExtension) { timeout 0 }
      }.to raise_error(ArgumentError)

      expect {
        max = Clacky::ApiExtension::MAX_TIMEOUT + 1
        Class.new(Clacky::ApiExtension) { timeout max }
      }.to raise_error(ArgumentError)
    end

    it "requires a handler block" do
      expect {
        Class.new(described_class) { get "/x" }
      }.to raise_error(ArgumentError, /missing handler block/)
    end
  end

  describe "halt helpers" do
    let(:dummy_route) do
      Clacky::ApiExtension::Route.new(
        method: :get, pattern: "/", regex: /\A\/\z/, param_names: [],
        block: proc {}, options: {}
      )
    end

    let(:instance) do
      described_class.allocate.tap do |inst|
        inst.instance_variable_set(:@req, nil)
        inst.instance_variable_set(:@res, nil)
        inst.instance_variable_set(:@route, dummy_route)
        inst.instance_variable_set(:@params, {})
        inst.instance_variable_set(:@http_server, nil)
      end
    end

    it "json raises Halt with serialized JSON and content type" do
      expect {
        instance.json(hello: "world")
      }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
        expect(halt.status).to eq(200)
        expect(halt.payload).to eq('{"hello":"world"}')
        expect(halt.content_type).to start_with("application/json")
      end
    end

    it "error! raises Halt with given status and message" do
      expect {
        instance.error!("nope", status: 422, hint: "bad input")
      }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
        expect(halt.status).to eq(422)
        payload = JSON.parse(halt.payload)
        expect(payload).to eq("error" => "nope", "hint" => "bad input")
      end
    end

    it "text raises Halt as text/plain" do
      expect { instance.text("hi") }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
        expect(halt.payload).to eq("hi")
        expect(halt.content_type).to start_with("text/plain")
      end
    end
  end

  describe "inheritance tracking" do
    it "registers each subclass into pending_subclasses" do
      before_count = described_class.pending_subclasses.size
      Class.new(described_class)
      expect(described_class.pending_subclasses.size).to eq(before_count + 1)
    end
  end
end
