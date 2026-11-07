# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"
require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer, "channel setup session target" do
  include HttpServerSpecHelpers

  let(:config) { Clacky::ChannelConfig.new }
  let(:registry) { double("registry", ensure: true) }
  let(:manager) { double("channel_manager", reload_platform: nil) }
  let(:server) do
    described_class.allocate.tap do |s|
      s.instance_variable_set(:@channel_manager, manager)
      s.instance_variable_set(:@registry, registry)
    end
  end

  before do
    allow(Clacky::ChannelConfig).to receive(:load).and_return(config)
    allow(config).to receive(:save)
    allow(Clacky::Channel::Adapters).to receive(:find).with(:weixin).and_return(nil)
  end

  def save_channel(body)
    res = fake_res
    server.api_save_channel("weixin", fake_req(method: "POST", path: "/api/channels/weixin", body: body), res)
    res
  end

  it "persists the invoking session before the adapter starts" do
    expect(config).to receive(:save).ordered do
      expect(config.instance(:weixin)["bind_session_id"]).to eq("original")
    end
    expect(manager).to receive(:reload_platform).with(:weixin, config, "default").ordered
    res = save_channel(token: "test", bind_session_id: "original")
    expect(res.status).to eq(200)
    # A restart retains the target until the first inbound message consumes it.
    restored = Clacky::ChannelConfig.new(channels: YAML.safe_load(config.to_yaml)["channels"])
    expect(restored.instance(:weixin)["bind_session_id"]).to eq("original")
  end

  it "rejects an invalid target before saving or starting the channel" do
    allow(registry).to receive(:ensure).with("missing").and_return(false)
    expect(config).not_to receive(:save)
    expect(manager).not_to receive(:reload_platform)
    expect(save_channel(token: "test", bind_session_id: "missing").status).to eq(422)
  end

  it "keeps legacy setup unchanged when no session is supplied" do
    expect(save_channel(token: "test").status).to eq(200)
    expect(config.instance(:weixin)).not_to have_key("bind_session_id")
  end
end
