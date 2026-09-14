# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "enterprise device onboarding" do
  let(:tmpdir) { Dir.mktmpdir("clacky_enterprise_device_login_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }
  let(:agent_config) do
    Clacky::AgentConfig.new(
      models: [{
        "id" => "old-model",
        "model" => "old-model",
        "base_url" => "https://old.example.com",
        "api_key" => "old-key",
        "type" => "default"
      }],
      clacky_license_server: Clacky::PlatformHttpClient::PRIMARY_HOST
    )
  end
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

  def fake_request(path:, body: nil)
    double(
      "request",
      request_method: "POST",
      path: path,
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

  def dispatch(path:, body:)
    response = fake_response
    server.send(:dispatch, fake_request(path: path, body: body), response)
    [response, JSON.parse(response.body)]
  end

  it "keeps the personal device flow on the default platform" do
    client = instance_double(Clacky::PlatformHttpClient)
    expect(Clacky::PlatformHttpClient).to receive(:new).with(no_args).twice.and_return(client)
    allow(client).to receive(:post).with(
      "/api/v1/device/authorize",
      hash_including(device_id: a_kind_of(String), device_info: a_kind_of(Hash))
    ).and_return(
      success: true,
      data: {
        "device_code" => "personal-device-code",
        "user_code" => "ABCD-EFGH",
        "verification_uri" => "https://www.openclacky.com/device",
        "interval" => 5
      }
    )
    allow(client).to receive(:post).with(
      "/api/v1/device/token",
      { device_code: "personal-device-code" }
    ).and_return(
      success: true,
      data: {
        "status" => "approved",
        "device_token" => "clacky-dt-personal",
        "user_id" => 7,
        "api_key" => "clacky-personal-key",
        "base_url" => "https://api.openclacky.com",
        "default_model" => "or-gemini-3-8-flash"
      }
    )
    identity = instance_double(Clacky::Identity)
    expect(Clacky::Identity).to receive(:load).and_return(identity)
    expect(identity).to receive(:bind!).with(
      device_token: "clacky-dt-personal",
      user_id: 7,
      platform_source: nil
    )
    expect(server).not_to receive(:deactivate_brand!)
    expect(server).not_to receive(:schedule_restart)

    start_response, start_body = dispatch(path: "/api/onboard/device/start", body: {})
    expect(start_response.status).to eq(200)
    expect(start_body).not_to have_key("platform_source")

    poll_response, poll_body = dispatch(
      path: "/api/onboard/device/poll",
      body: { device_code: "personal-device-code" }
    )

    expect(poll_response.status).to eq(200)
    expect(poll_body).to include(
      "ok" => true,
      "status" => "approved",
      "source_changed" => false,
      "restarting" => false
    )
    expect(agent_config.models.last).not_to have_key("enterprise_managed")
    expect(agent_config.models.last).not_to have_key("managed_models")
  end

  it "starts authorization against the normalized candidate source without saving it" do
    client = instance_double(Clacky::PlatformHttpClient)
    expect(Clacky::PlatformHttpClient).to receive(:new)
      .with(host: "https://enterprise.example.com")
      .and_return(client)
    expect(client).to receive(:post).with(
      "/api/v1/device/authorize",
      hash_including(device_id: a_kind_of(String), device_info: a_kind_of(Hash))
    ).and_return(
      success: true,
      data: {
        "device_code" => "device-code",
        "user_code" => "ABCD-EFGH",
        "verification_uri" => "https://enterprise.example.com/device",
        "interval" => 5
      }
    )
    expect(agent_config).not_to receive(:save)

    response, body = dispatch(
      path: "/api/onboard/device/start",
      body: { platform_source: "HTTPS://Enterprise.EXAMPLE.com:443/" }
    )

    expect(response.status).to eq(200)
    expect(body).to include(
      "ok" => true,
      "device_code" => "device-code",
      "platform_source" => "https://enterprise.example.com"
    )
    expect(agent_config.clacky_license_server).to eq(Clacky::PlatformHttpClient::PRIMARY_HOST)
  end

  it "rejects an invalid candidate source without changing local state" do
    expect(Clacky::PlatformHttpClient).not_to receive(:new)
    expect(agent_config).not_to receive(:save)

    response, body = dispatch(
      path: "/api/onboard/device/start",
      body: { platform_source: "https://enterprise.example.com/admin?token=secret" }
    )

    expect(response.status).to eq(422)
    expect(body).to include("ok" => false)
    expect(agent_config.clacky_license_server).to eq(Clacky::PlatformHttpClient::PRIMARY_HOST)
  end

  it "keeps platform, model, identity, and brand unchanged while approval is pending" do
    http_server = server
    client = instance_double(Clacky::PlatformHttpClient)
    allow(Clacky::PlatformHttpClient).to receive(:new)
      .with(host: "https://enterprise.example.com")
      .and_return(client)
    allow(client).to receive(:post).and_return(success: true, data: { "status" => "pending" })
    expect(agent_config).not_to receive(:save)
    expect(Clacky::Identity).not_to receive(:load)
    expect(Clacky::BrandConfig).not_to receive(:load)
    expect(http_server).not_to receive(:schedule_restart)

    response, body = dispatch(
      path: "/api/onboard/device/poll",
      body: { device_code: "device-code", platform_source: "https://enterprise.example.com" }
    )

    expect(response.status).to eq(200)
    expect(body).to include("ok" => true, "status" => "pending")
    expect(agent_config.models.first["model"]).to eq("old-model")
    expect(agent_config.clacky_license_server).to eq(Clacky::PlatformHttpClient::PRIMARY_HOST)
  end

  it "commits identity, a concrete default model, and platform source only after approval" do
    http_server = server
    client = instance_double(Clacky::PlatformHttpClient)
    allow(Clacky::PlatformHttpClient).to receive(:new)
      .with(host: "https://enterprise.example.com")
      .and_return(client)
    allow(client).to receive(:post).and_return(
      success: true,
      data: {
        "status" => "approved",
        "device_token" => "clacky-dt-secret",
        "user_id" => 42,
        "api_key" => "clacky-dt-secret",
        "base_url" => "https://models.enterprise.example.com",
        "default_model" => "or-gemini-3-5-flash",
        "models" => %w[
          or-gemini-3-5-flash
          abs-claude-sonnet-5
          dsk-deepseek-v4-pro
        ]
      }
    )
    identity = instance_double(Clacky::Identity)
    expect(Clacky::Identity).to receive(:load).and_return(identity)
    expect(identity).to receive(:bind!).with(device_token: "clacky-dt-secret", user_id: 42, platform_source: "https://enterprise.example.com")
    expect(http_server).to receive(:deactivate_brand!).once
    expect(agent_config).to receive(:save).once.and_call_original
    expect(http_server).to receive(:schedule_restart).once

    response, body = dispatch(
      path: "/api/onboard/device/poll",
      body: { device_code: "device-code", platform_source: "https://enterprise.example.com" }
    )

    expect(response.status).to eq(200)
    expect(body).to include(
      "ok" => true,
      "status" => "approved",
      "default_model" => "or-gemini-3-5-flash",
      "platform_source" => "https://enterprise.example.com",
      "source_changed" => true,
      "restarting" => true
    )
    expect(agent_config.clacky_license_server).to eq("https://enterprise.example.com")
    expect(agent_config.models.count { |model| model["type"] == "default" }).to eq(1)
    expect(agent_config.models.last).to include(
      "model" => "or-gemini-3-5-flash",
      "base_url" => "https://models.enterprise.example.com",
      "api_key" => "clacky-dt-secret",
      "enterprise_managed" => true,
      "managed_models" => %w[
        or-gemini-3-5-flash
        abs-claude-sonnet-5
        dsk-deepseek-v4-pro
      ],
      "type" => "default"
    )
  end

  it "does not save a partial approved response" do
    http_server = server
    client = instance_double(Clacky::PlatformHttpClient)
    allow(Clacky::PlatformHttpClient).to receive(:new)
      .with(host: "https://enterprise.example.com")
      .and_return(client)
    allow(client).to receive(:post).and_return(
      success: true,
      data: {
        "status" => "approved",
        "device_token" => "clacky-dt-secret",
        "user_id" => 42,
        "api_key" => "clacky-dt-secret",
        "base_url" => "https://models.enterprise.example.com"
      }
    )
    expect(agent_config).not_to receive(:save)
    expect(Clacky::Identity).not_to receive(:load)
    expect(Clacky::BrandConfig).not_to receive(:load)
    expect(http_server).not_to receive(:schedule_restart)

    response, body = dispatch(
      path: "/api/onboard/device/poll",
      body: { device_code: "device-code", platform_source: "https://enterprise.example.com" }
    )

    expect(response.status).to eq(502)
    expect(body).to include("ok" => false, "status" => "error")
    expect(agent_config.models.first["model"]).to eq("old-model")
    expect(agent_config.clacky_license_server).to eq(Clacky::PlatformHttpClient::PRIMARY_HOST)
  end

  it "rejects an invalid enterprise model catalog before persisting identity" do
    client = instance_double(Clacky::PlatformHttpClient)
    allow(Clacky::PlatformHttpClient).to receive(:new)
      .with(host: "https://enterprise.example.com")
      .and_return(client)
    allow(client).to receive(:post).and_return(
      success: true,
      data: {
        "status" => "approved",
        "device_token" => "clacky-dt-secret",
        "user_id" => 42,
        "api_key" => "clacky-dt-secret",
        "base_url" => "https://models.enterprise.example.com",
        "default_model" => "../../not-a-model",
        "models" => ["../../not-a-model"]
      }
    )
    expect(agent_config).not_to receive(:save)
    expect(Clacky::Identity).not_to receive(:load)

    response, body = dispatch(
      path: "/api/onboard/device/poll",
      body: { device_code: "device-code", platform_source: "https://enterprise.example.com" }
    )

    expect(response.status).to eq(422)
    expect(body).to include("ok" => false, "status" => "error")
    expect(agent_config.models).to contain_exactly(hash_including("model" => "old-model"))
  end

  it "does not mutate the model or platform source when identity persistence fails" do
    client = instance_double(Clacky::PlatformHttpClient)
    allow(Clacky::PlatformHttpClient).to receive(:new)
      .with(host: "https://enterprise.example.com")
      .and_return(client)
    allow(client).to receive(:post).and_return(
      success: true,
      data: {
        "status" => "approved",
        "device_token" => "clacky-dt-secret",
        "user_id" => 42,
        "api_key" => "clacky-dt-secret",
        "base_url" => "https://models.enterprise.example.com",
        "default_model" => "or-gemini-3-5-flash"
      }
    )
    identity = instance_double(Clacky::Identity)
    allow(Clacky::Identity).to receive(:load).and_return(identity)
    allow(identity).to receive(:bind!).and_raise(IOError, "disk full")

    response, = dispatch(
      path: "/api/onboard/device/poll",
      body: { device_code: "device-code", platform_source: "https://enterprise.example.com" }
    )

    expect(response.status).to eq(500)
    expect(agent_config.models).to contain_exactly(hash_including("model" => "old-model", "type" => "default"))
    expect(agent_config.clacky_license_server).to eq(Clacky::PlatformHttpClient::PRIMARY_HOST)
  end
end
