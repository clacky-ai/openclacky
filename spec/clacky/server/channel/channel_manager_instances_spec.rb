# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"

RSpec.describe Clacky::Channel::ChannelManager, "multiple instances per platform" do
  let(:fake_adapter_class) do
    Class.new(Clacky::Channel::Adapters::Base) do
      attr_reader :config

      def initialize(config)
        @config = config
      end

      def platform_id
        :fake
      end

      def validate_config(_config)
        []
      end

      def start
        nil
      end

      def stop
        nil
      end

      def send_text(*)
        nil
      end
    end
  end

  let(:channel_config) do
    Clacky::ChannelConfig.new(channels: {
      "fake" => [
        { "id" => "default", "enabled" => true, "token" => "a" },
        { "id" => "work", "name" => "Company", "enabled" => true, "token" => "b" }
      ]
    })
  end

  let(:sessions) do
    [
      { id: "s1", channel_keys: ["fake:chat:c1"] },
      { id: "s2", channel_keys: ["fake#work:chat:c2"] }
    ]
  end

  let(:registry) do
    list = sessions
    double("registry").tap do |r|
      allow(r).to receive(:list).with(limit: nil, archived: nil).and_return([])
      allow(r).to receive(:list).with(archived: nil) { list.map { |s| { id: s[:id] } } }
      allow(r).to receive(:with_session) { |sid, &blk| blk.call(list.find { |s| s[:id] == sid }) }
    end
  end

  let(:manager) do
    described_class.new(
      session_registry: registry,
      session_builder: ->(**_kw) { "s1" },
      run_agent_task: ->(*) {},
      interrupt_session: ->(*) {},
      channel_config: channel_config
    )
  end

  before do
    allow(Clacky::Channel::Adapters).to receive(:find).with(:fake).and_return(fake_adapter_class)
  end

  after do
    manager.stop
  end

  it "starts one adapter per enabled instance and tags each with its id and name" do
    manager.start

    expect(manager.running_instances).to contain_exactly(
      { platform: :fake, instance_id: "default" },
      { platform: :fake, instance_id: "work" }
    )
    expect(manager.adapter_for(:fake, "default").instance_name).to eq("")
    expect(manager.adapter_for(:fake, "work").instance_name).to eq("Company")
    expect(manager.adapter_for(:fake, "work").config[:token]).to eq("b")
  end

  it "resolves a nil id to the default instance and never borrows another instance" do
    manager.start

    expect(manager.adapter_for(:fake)).to eq(manager.adapter_for(:fake, "default"))
    expect(manager.adapter_for(:fake, "missing")).to be_nil
  end

  it "scopes known users to one instance" do
    manager.start

    expect(manager.known_users(:fake, "default")).to eq(["c1"])
    expect(manager.known_users(:fake, "work")).to eq(["c2"])
    expect(manager.known_users(:fake)).to contain_exactly("c1", "c2")
  end

  it "reloads only the requested instance" do
    manager.start
    untouched = manager.adapter_for(:fake, "default")
    replaced  = manager.adapter_for(:fake, "work")

    manager.reload_platform(:fake, channel_config, "work")

    expect(manager.adapter_for(:fake, "default")).to eq(untouched)
    expect(manager.adapter_for(:fake, "work")).not_to eq(replaced)
    expect(manager.running_instances.length).to eq(2)
  end

  it "does not restart an instance that is disabled" do
    manager.start
    channel_config.disable_platform(:fake, "work")

    manager.reload_platform(:fake, channel_config, "work")

    expect(manager.adapter_for(:fake, "work")).to be_nil
    expect(manager.adapter_for(:fake, "default")).not_to be_nil
  end

  it "stops an adapter whose instance was deleted from the config" do
    manager.start
    expect(manager.adapter_for(:fake, "work")).not_to be_nil

    channel_config.remove_platform(:fake, "work")
    manager.reload_platform(:fake, channel_config, "work")

    expect(manager.adapter_for(:fake, "work")).to be_nil
    expect(manager.adapter_for(:fake, "default")).not_to be_nil
    expect(manager.running_instances.length).to eq(1)
  end
end
