# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "platform source settings" do
  let(:tmpdir) { Dir.mktmpdir("clacky_platform_source_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }
  let(:agent_config) { Clacky::AgentConfig.new(models: []) }
  let(:server) do
    described_class.new(
      host: "127.0.0.1",
      port: 0,
      agent_config: agent_config,
      client_factory: -> { double("client") },
      sessions_dir: File.join(tmpdir, "sessions"),
      master_pid: 12_345
    )
  end

  before do
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
  end

  around do |example|
    ClimateControl.modify("CLACKY_LICENSE_SERVER" => nil) { example.run }
  end

  after { FileUtils.rm_rf(tmpdir) }

  def fake_request(method:, body: nil)
    double(
      "request",
      request_method: method,
      path: "/api/config/settings",
      body: body&.to_json,
      query_string: "",
      "[]": nil
    )
  end

  def fake_response
    response = double("response").as_null_object
    allow(response).to receive(:status=) { |value| response.instance_variable_set(:@status, value) }
    allow(response).to receive(:body=) { |value| response.instance_variable_set(:@body, value) }
    allow(response).to receive(:status) { response.instance_variable_get(:@status) }
    allow(response).to receive(:body) { response.instance_variable_get(:@body) }
    response
  end

  def dispatch(request, response)
    server.send(:dispatch, request, response)
  end

  def response_body(response)
    JSON.parse(response.body)
  end

  describe "GET /api/config/settings" do
    it "returns the saved default homepage preference" do
      agent_config.default_homepage = "qingshi-workbench"
      response = fake_response

      dispatch(fake_request(method: "GET"), response)

      expect(response.status).to eq(200)
      expect(response_body(response)["default_homepage"]).to eq("qingshi-workbench")
    end

    it "returns the official source when neither a saved value nor an environment override exists" do
      response = fake_response

      dispatch(fake_request(method: "GET"), response)

      expect(response.status).to eq(200)
      expect(response_body(response)["clacky_license_server"]).to eq(
        Clacky::PlatformHttpClient::PRIMARY_HOST
      )
    end

    it "returns an inherited environment override when no value has been saved" do
      ClimateControl.modify(
        "CLACKY_LICENSE_SERVER" => "https://enterprise.example.com/"
      ) do
        response = fake_response

        dispatch(fake_request(method: "GET"), response)

        expect(response_body(response)["clacky_license_server"]).to eq(
          "https://enterprise.example.com"
        )
      end
    end

    it "prefers a saved value over an inherited environment override" do
      agent_config.clacky_license_server = "https://saved.example.com"

      ClimateControl.modify(
        "CLACKY_LICENSE_SERVER" => "https://wrapper.example.com"
      ) do
        response = fake_response

        dispatch(fake_request(method: "GET"), response)

        expect(response_body(response)["clacky_license_server"]).to eq(
          "https://saved.example.com"
        )
      end
    end
  end

  describe "PATCH /api/config/settings" do
    it "saves a default homepage without restarting" do
      http_server = server
      allow(http_server).to receive(:schedule_restart)
      response = fake_response

      dispatch(
        fake_request(method: "PATCH", body: { default_homepage: "qingshi-workbench" }),
        response
      )

      expect(response.status).to eq(200)
      expect(response_body(response)).to include(
        "ok" => true,
        "default_homepage" => "qingshi-workbench"
      )
      expect(agent_config.default_homepage).to eq("qingshi-workbench")
      expect(Clacky::AgentConfig.load(config_file).default_homepage).to eq("qingshi-workbench")
      expect(http_server).not_to have_received(:schedule_restart)
    end

    it "clears the saved preference when default_homepage is null" do
      agent_config.default_homepage = "native"
      response = fake_response

      dispatch(fake_request(method: "PATCH", body: { default_homepage: nil }), response)

      expect(response.status).to eq(200)
      expect(response_body(response)["default_homepage"]).to be_nil
      expect(agent_config.default_homepage).to be_nil
    end

    it "rejects invalid default homepage identifiers without saving" do
      expect(agent_config).not_to receive(:save)
      response = fake_response

      dispatch(fake_request(method: "PATCH", body: { default_homepage: "../bad route" }), response)

      expect(response.status).to eq(422)
      expect(response_body(response)["ok"]).to be(false)
      expect(agent_config.default_homepage).to be_nil
    end

    it "normalizes, saves, deactivates once, and schedules a restart when the source changes" do
      http_server = server
      brand = instance_double(Clacky::BrandConfig, deactivate!: { success: true })
      allow(Clacky::BrandConfig).to receive(:load).and_return(
        brand,
        Clacky::BrandConfig.new({})
      )
      expect(brand).to receive(:deactivate!).ordered.and_return(success: true)
      expect(agent_config).to receive(:save).ordered.and_call_original
      expect(http_server).to receive(:json_response).ordered.and_call_original
      expect(http_server).to receive(:schedule_restart).ordered

      response = fake_response
      dispatch(
        fake_request(
          method: "PATCH",
          body: { clacky_license_server: "HTTPS://Enterprise.EXAMPLE.com:443/" }
        ),
        response
      )

      expect(response.status).to eq(200)
      expect(response_body(response)).to include(
        "ok" => true,
        "clacky_license_server" => "https://enterprise.example.com",
        "source_changed" => true,
        "restarting" => true
      )
      expect(agent_config.clacky_license_server).to eq("https://enterprise.example.com")
    end

    it "saves without deactivating or restarting when the effective source is unchanged" do
      agent_config.clacky_license_server = "https://enterprise.example.com"
      http_server = server
      allow(agent_config).to receive(:save).and_call_original
      allow(http_server).to receive(:schedule_restart)
      expect(Clacky::BrandConfig).not_to receive(:load)

      response = fake_response
      dispatch(
        fake_request(
          method: "PATCH",
          body: { clacky_license_server: "https://enterprise.example.com/" }
        ),
        response
      )

      expect(response.status).to eq(200)
      expect(response_body(response)).to include(
        "source_changed" => false,
        "restarting" => false
      )
      expect(agent_config).to have_received(:save).once
      expect(http_server).not_to have_received(:schedule_restart)
    end

    it "does not deactivate, save, or restart for invalid origins" do
      http_server = server
      allow(http_server).to receive(:schedule_restart)
      expect(agent_config).not_to receive(:save)
      expect(Clacky::BrandConfig).not_to receive(:load)

      invalid_sources = [
        "",
        "ftp://enterprise.example.com",
        "https://user:pass@enterprise.example.com",
        "https://enterprise.example.com/api",
        "https://enterprise.example.com?region=cn",
        "https://enterprise.example.com#settings",
        "https://"
      ]

      invalid_sources.each do |source|
        response = fake_response
        dispatch(
          fake_request(method: "PATCH", body: { clacky_license_server: source }),
          response
        )

        expect(response.status).to eq(422)
        expect(response_body(response)["ok"]).to be(false)
      end

      expect(http_server).not_to have_received(:schedule_restart)
    end
  end

  describe "an in-flight distribution refresh" do
    it "does not restore the old source brand after switching to the official source" do
      brand_file = File.join(tmpdir, "brand.yml")
      stub_const("Clacky::BrandConfig::BRAND_FILE", brand_file)
      stub_const("Clacky::BrandConfig::CONFIG_DIR", tmpdir)

      started = Queue.new
      release = Queue.new
      fake_client = instance_double(Clacky::PlatformHttpClient)
      allow(fake_client).to receive(:get) do
        started << true
        release.pop
        {
          success: true,
          data: {
            "distribution" => {
              "product_name" => "Old Enterprise",
              "package_name" => nil
            }
          }
        }
      end
      allow(Clacky::PlatformHttpClient).to receive(:new).and_return(fake_client)

      brand = Clacky::BrandConfig.new({})
      allow(brand).to receive(:sync_free_skills_async!)
      allow(Clacky::BrandConfig).to receive(:load).and_return(brand)

      ClimateControl.modify(
        "CLACKY_LICENSE_SERVER" => "https://enterprise.example.com"
      ) do
        agent_config.clacky_license_server = "https://enterprise.example.com"
        server.send(:trigger_async_distribution_refresh!)
        Timeout.timeout(2) { started.pop }

        agent_config.clacky_license_server = Clacky::PlatformHttpClient::PRIMARY_HOST
        release << true

        Timeout.timeout(2) do
          loop do
            inflight = described_class::BRAND_DIST_REFRESH_MUTEX.synchronize do
              described_class.class_variable_get(:@@brand_dist_refresh_inflight)
            end
            break unless inflight

            sleep 0.01
          end
        end
      end

      expect(brand.product_name).to be_nil
      expect(File).not_to exist(brand_file)
      expect(brand).not_to have_received(:sync_free_skills_async!)
    end
  end
end
