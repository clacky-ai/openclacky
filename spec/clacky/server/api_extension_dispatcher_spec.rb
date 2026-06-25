# frozen_string_literal: true

require "spec_helper"
require "webrick"
require "stringio"

RSpec.describe Clacky::Server::ApiExtensionDispatcher do
  before { Clacky::ApiExtension.reset_registry! }

  # Fake req/res that look enough like WEBrick objects for the dispatcher.
  let(:res) { WEBrick::HTTPResponse.new(WEBrick::Config::HTTP) }

  def make_req(method, path, body: nil)
    req = double("req",
      path: path,
      request_method: method,
      body: body,
      query: {})
    req
  end

  def register_ext(id, klass)
    klass.ext_id = id
    klass.ext_dir = Dir.mktmpdir
    klass.meta = {}
    Clacky::ApiExtension.register(id, klass)
  end

  describe ".handle" do
    it "routes to the matching handler and writes a JSON response" do
      ext = Class.new(Clacky::ApiExtension) do
        get "/items/:id" do
          json(id: params[:id])
        end
      end
      register_ext("things", ext)

      req = make_req("GET", "/api/ext/things/items/42")
      described_class.handle(req, res, http_server: nil)

      expect(res.status).to eq(200)
      expect(res.content_type).to start_with("application/json")
      expect(JSON.parse(res.body)).to eq("id" => "42")
    end

    it "returns 404 when extension id is unknown" do
      req = make_req("GET", "/api/ext/missing/foo")
      described_class.handle(req, res, http_server: nil)
      expect(res.status).to eq(404)
    end

    it "returns 404 when no route matches" do
      ext = Class.new(Clacky::ApiExtension) do
        get "/known" do
          json(ok: true)
        end
      end
      register_ext("ext1", ext)

      req = make_req("GET", "/api/ext/ext1/unknown")
      described_class.handle(req, res, http_server: nil)
      expect(res.status).to eq(404)
    end

    it "wraps handler exceptions in a 500 JSON envelope" do
      ext = Class.new(Clacky::ApiExtension) do
        get "/boom" do
          raise "kaboom"
        end
      end
      register_ext("ext2", ext)

      req = make_req("GET", "/api/ext/ext2/boom")
      described_class.handle(req, res, http_server: nil)

      expect(res.status).to eq(500)
      expect(JSON.parse(res.body)).to eq("error" => "kaboom")
    end

    it "honors error! with a custom status" do
      ext = Class.new(Clacky::ApiExtension) do
        post "/v" do
          error!("bad", status: 422)
        end
      end
      register_ext("ext3", ext)

      req = make_req("POST", "/api/ext/ext3/v")
      described_class.handle(req, res, http_server: nil)
      expect(res.status).to eq(422)
      expect(JSON.parse(res.body)["error"]).to eq("bad")
    end

    it "returns 503 when the handler exceeds its timeout" do
      ext = Class.new(Clacky::ApiExtension) do
        get "/slow", timeout: 0.05 do
          sleep 1
          json(ok: true)
        end
      end
      register_ext("ext4", ext)

      req = make_req("GET", "/api/ext/ext4/slow")
      described_class.handle(req, res, http_server: nil)
      expect(res.status).to eq(503)
    end
  end

  describe ".public_path?" do
    it "returns true only for explicitly declared public routes" do
      ext = Class.new(Clacky::ApiExtension) do
        public_endpoint "/in"
        post "/in" do
          json(ok: true)
        end
        get "/private" do
          json(ok: true)
        end
      end
      register_ext("hook", ext)

      expect(described_class.public_path?("/api/ext/hook/in", "POST")).to be true
      expect(described_class.public_path?("/api/ext/hook/private", "GET")).to be false
      expect(described_class.public_path?("/api/ext/missing/in", "POST")).to be false
    end
  end
end
