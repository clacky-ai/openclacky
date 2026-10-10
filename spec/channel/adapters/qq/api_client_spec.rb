# frozen_string_literal: true

require "clacky/server/channel/adapters/qq/api_client"
require "webrick"
require "json"

RSpec.describe Clacky::Channel::Adapters::Qq::ApiClient do
  let(:client) do
    described_class.new(app_id: "app-1", app_secret: "secret-1")
  end

  describe "#initialize" do
    it "uses the production base url by default" do
      expect(client.base_url).to eq(described_class::DEFAULT_BASE_URL)
    end

    it "accepts an explicit base url" do
      custom = described_class.new(
        app_id: "app-1", app_secret: "secret-1",
        base_url: "https://example.test"
      )
      expect(custom.base_url).to eq("https://example.test")
    end

    it "strips trailing slashes from the base url" do
      custom = described_class.new(
        app_id: "app-1", app_secret: "secret-1",
        base_url: "https://example.test///"
      )
      expect(custom.base_url).to eq("https://example.test")
    end
  end

  describe "ApiError" do
    it "carries an optional code and http status" do
      err = described_class::ApiError.new("bad", code: 100, http_status: 400)
      expect(err.message).to eq("bad")
      expect(err.code).to eq(100)
      expect(err.http_status).to eq(400)
    end
  end

  describe "#parse_response" do
    def parse(status, body)
      res = instance_double("Net::HTTPResponse", code: status.to_s, body: body)
      client.send(:parse_response, res)
    end

    it "passes through an empty body as an empty hash" do
      expect(parse(204, "")).to eq({})
    end

    it "raises for non-JSON bodies" do
      expect { parse(500, "<html>") }.to raise_error(
        an_instance_of(described_class::ApiError).and(having_attributes(http_status: 500))
      )
    end

    it "maps a non-zero business code delivered with HTTP 200" do
      body = { "code" => 11_264, "message" => "no permission" }.to_json
      expect { parse(200, body) }.to raise_error(
        an_instance_of(described_class::ApiError)
          .and(having_attributes(code: 11_264, http_status: 200, message: "no permission"))
      )
    end

    it "falls back to the code in the message when message is blank" do
      expect { parse(200, { "code" => 999 }.to_json) }.to raise_error(
        described_class::ApiError, "QQ API code 999"
      )
    end

    it "maps non-2xx HTTP statuses without a business code" do
      expect { parse(401, { "message" => "bad token" }.to_json) }.to raise_error(
        an_instance_of(described_class::ApiError).and(having_attributes(http_status: 401))
      )
    end

    it "accepts a successful response with code 0" do
      expect(parse(200, { "code" => 0, "id" => "x" }.to_json)).to eq("code" => 0, "id" => "x")
    end
  end

  describe "live HTTP via WEBrick" do
    # Exercises build_request + token refresh + error mapping end to end without
    # touching the real QQ API.
    let(:token_requests) { [] }
    let(:api_requests)   { [] }
    let(:server) do
      token_requests_local = token_requests
      api_requests_local   = api_requests
      WEBrick::HTTPServer.new(
        Port: 0, Logger: WEBrick::Log.new("/dev/null"), AccessLog: []
      ).tap do |srv|
        srv.mount_proc("/app/getAppAccessToken") do |req, res|
          token_requests_local << req.header
          res["Content-Type"] = "application/json"
          res.body = { access_token: "tok-123", expires_in: "7200" }.to_json
        end
        srv.mount_proc("/gateway") do |req, res|
          api_requests_local << req.header
          res["Content-Type"] = "application/json"
          res.body = { url: "wss://gw.example/g" }.to_json
        end
      end
    end
    let(:port) { server.config[:Port] }
    let(:live_client) do
      described_class.new(
        app_id: "app-1", app_secret: "secret-1",
        base_url: "http://127.0.0.1:#{port}",
        open_timeout: 3, read_timeout: 3
      )
    end

    before do
      stub_const("#{described_class}::TOKEN_URL", "http://127.0.0.1:#{port}/app/getAppAccessToken")
      Thread.new { server.start }
      sleep 0.1
    end
    after { server.shutdown }

    it "fetches a token, caches it, and attaches Authorization + X-Union-Appid" do
      expect(live_client.access_token).to eq("tok-123")
      live_client.access_token
      expect(token_requests.size).to eq(1)

      expect(live_client.gateway_url).to eq("wss://gw.example/g")
      headers = api_requests.last
      expect(headers["authorization"]).to eq(["QQBot tok-123"])
      expect(headers["x-union-appid"]).to eq(["app-1"])
    end

    it "does not attach Authorization/X-Union-Appid on the token request" do
      live_client.access_token
      headers = token_requests.last
      expect(headers).not_to have_key("authorization")
      expect(headers).not_to have_key("x-union-appid")
    end

    it "raises ApiError when the token response lacks access_token" do
      srv2 = WEBrick::HTTPServer.new(
        Port: 0, Logger: WEBrick::Log.new("/dev/null"), AccessLog: []
      )
      srv2.mount_proc("/app/getAppAccessToken") do |_req, res|
        res["Content-Type"] = "application/json"
        res.body = { "code" => 10004, "message" => "机器人不存在" }.to_json
      end
      Thread.new { srv2.start }
      sleep 0.1
      bad = described_class.new(
        app_id: "app-1", app_secret: "nope",
        open_timeout: 3, read_timeout: 3
      )
      stub_const("#{described_class}::TOKEN_URL",
                 "http://127.0.0.1:#{srv2.config[:Port]}/app/getAppAccessToken")
      expect { bad.access_token }.to raise_error(described_class::ApiError, /机器人不存在/)
      srv2.shutdown
    end
  end
end
