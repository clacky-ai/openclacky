# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "clacky/server/http_server"
require "clacky/agent_config"
require "clacky/brand_config"

# Tests that GET /api/brand/status exposes homepage_url + logo_url so the
# Web UI's Share module can render brand-aware share content (and never leak
# OpenClacky branding into a white-labelled build).

module HttpServerBrandSpecHelpers
  def fake_res
    res = double("res").as_null_object
    allow(res).to receive(:status=) { |v| res.instance_variable_set(:@status, v) }
    allow(res).to receive(:body=)   { |v| res.instance_variable_set(:@body, v) }
    allow(res).to receive(:content_type=)
    allow(res).to receive(:[]=)
    allow(res).to receive(:status)  { res.instance_variable_get(:@status) }
    allow(res).to receive(:body)    { res.instance_variable_get(:@body) }
    res
  end

  def parsed_body(res)
    JSON.parse(res.body)
  end

  def build_server
    cfg = Clacky::AgentConfig.new(models: [{
      "model"            => "test-model",
      "api_key"          => "sk-testkey1234567890abcd",
      "base_url"         => "https://api.example.com",
      "anthropic_format" => true,
      "type"             => "default"
    }])
    Clacky::Server::HttpServer.new(
      host:           "127.0.0.1",
      port:           0,
      agent_config:   cfg,
      client_factory: -> { double("client") },
      sessions_dir:   Dir.mktmpdir("clacky_brand_spec_sessions")
    )
  end
end

RSpec.describe Clacky::Server::HttpServer, "GET /api/brand/status" do
  include HttpServerBrandSpecHelpers

  let(:server) { build_server }

  before { server } # construct before stubbing BrandConfig.load

  context "when not branded" do
    it "returns branded: false without brand fields" do
      brand = instance_double(Clacky::BrandConfig, branded?: false, activated?: false)
      allow(Clacky::BrandConfig).to receive(:load).and_return(brand)

      res = fake_res
      server.send(:api_brand_status, res)

      body = parsed_body(res)
      expect(body["branded"]).to be(false)
      expect(body).not_to have_key("homepage_url")
    end
  end

  context "when branded and activated" do
    it "exposes homepage_url and logo_url" do
      brand = instance_double(Clacky::BrandConfig,
        branded?:           true,
        activated?:         true,
        heartbeat_due?:     false,
        expired?:           false,
        grace_period_exceeded?: false,
        license_expires_at: nil,
        product_name:       "JohnAI",
        homepage_url:       "https://johnai.com",
        logo_url:           "https://johnai.com/logo.png",
        user_licensed?:     false,
        license_user_id:    nil)
      allow(Clacky::BrandConfig).to receive(:load).and_return(brand)

      res = fake_res
      server.send(:api_brand_status, res)

      body = parsed_body(res)
      expect(body["branded"]).to be(true)
      expect(body["product_name"]).to eq("JohnAI")
      expect(body["homepage_url"]).to eq("https://johnai.com")
      expect(body["logo_url"]).to eq("https://johnai.com/logo.png")
    end
  end

  context "when branded but not yet activated" do
    it "still exposes homepage_url and logo_url" do
      brand = instance_double(Clacky::BrandConfig,
        branded?:                  true,
        activated?:                false,
        distribution_refresh_due?: false,
        product_name:              "JohnAI",
        homepage_url:              "https://johnai.com",
        logo_url:                  "https://johnai.com/logo.png")
      allow(Clacky::BrandConfig).to receive(:load).and_return(brand)

      res = fake_res
      server.send(:api_brand_status, res)

      body = parsed_body(res)
      expect(body["needs_activation"]).to be(true)
      expect(body["homepage_url"]).to eq("https://johnai.com")
      expect(body["logo_url"]).to eq("https://johnai.com/logo.png")
    end
  end
end
