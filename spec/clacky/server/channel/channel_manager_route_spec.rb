# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"

RSpec.describe Clacky::Channel::ChannelManager, "route_message input behavior" do
  let(:registry) { Clacky::Server::SessionRegistry.new(agent_config: Clacky::AgentConfig.new) }
  let(:agent) { double("agent") }
  let(:adapter) { double("adapter", platform_id: :feishu, instance_id: "default") }
  let(:interrupts) { [] }
  let(:runs) { [] }
  let(:channel_config) do
    Clacky::ChannelConfig.new
  end
  let(:manager) do
    described_class.new(
      session_registry:  registry,
      session_builder:  ->(_opts) { raise "should not auto-create a session" },
      run_agent_task:   ->(_sid, _ag, &task) { runs << :task; task&.call },
      interrupt_session: ->(sid) { interrupts << sid },
      channel_config:   channel_config
    )
  end
  let(:event) do
    { platform: :feishu, chat_id: "chat-1", user_id: "user-1", text: "hello", files: [] }
  end

  before do
    registry.create(session_id: "s")
    registry.with_session("s") do |s|
      s[:agent]  = agent
      s[:status] = :running
    end
    allow(manager).to receive(:resolve_session).and_return("s")
    allow(agent).to receive(:channel_info=)
    allow(agent).to receive(:run)
    allow(manager).to receive(:build_prompt_with_context).and_return("prompt")
  end

  it "interrupts the running task instead of queueing the message" do
    expect(agent).not_to receive(:enqueue_input)
    expect(agent).to receive(:run).with("prompt", files: [], display_text: "hello")

    manager.send(:route_message, adapter, event)

    expect(interrupts).to eq(["s"])
    expect(runs).to eq([:task])
  end

  it "interrupts even when a previous task thread has already finished" do
    dead_thread = double("dead-thread", alive?: false, join: nil)
    registry.with_session("s") { |s| s[:thread] = dead_thread }

    expect(agent).not_to receive(:enqueue_input)
    manager.send(:route_message, adapter, event)

    expect(interrupts).to eq(["s"])
    expect(runs).to eq([:task])
  end

  it "runs the message as a new task on an idle session without interrupting" do
    registry.with_session("s") { |s| s[:status] = :idle }

    expect(agent).not_to receive(:enqueue_input)
    manager.send(:route_message, adapter, event)

    expect(interrupts).to be_empty
    expect(runs).to eq([:task])
  end

  it "retains the safety valve when the interrupted task does not stop in time" do
    live_thread = double("live-thread", alive?: true, join: nil)
    registry.with_session("s") { |s| s[:thread] = live_thread }

    expect(agent).to receive(:enqueue_input)
      .with("prompt", hash_including(files: [], display_text: "hello", source: :channel))
    expect(adapter).to receive(:send_text)
      .with("chat-1", "The current task is still stopping. Your message remains queued.")
    expect(manager).not_to receive(:run_agent_task)

    manager.send(:route_message, adapter, event)

    expect(interrupts).to eq(["s"])
    expect(runs).to be_empty
  end
  describe "setup from the current conversation" do
    let(:channel_config) do
      Clacky::ChannelConfig.new(channels: {
        "feishu" => [{ "id" => "default", "bind_session_id" => "original" },
                     { "id" => "other" }]
      })
    end

    before do
      allow(channel_config).to receive(:save)
      registry.create(session_id: "original")
      registry.with_session("original") { |s| s[:agent] = agent; s[:status] = :idle }
      allow(registry).to receive(:list).and_return([{ id: "s", source: "manual" }, { id: "original", source: "manual" }])
      allow(manager).to receive(:resolve_session).and_call_original
    end

    it "runs the first ordinary message in the original session without a pairing command" do
      expect(manager).not_to receive(:auto_create_session)
      expect(agent).to receive(:channel_info=).with(hash_including(chat_id: "chat-1")).at_least(:once)
      expect(agent).to receive(:run).with("prompt", files: [], display_text: "hello")
      manager.route_message(adapter, event)
      expect(manager.resolve_session(event)).to eq("original")
      expect(channel_config.instance(:feishu)["bind_session_id"]).to be_nil
      expect(channel_config).to have_received(:save)
      # The setup target is consumed, not used as a default for every chat.
      expect(manager.resolve_session(event.merge(chat_id: "another-chat"))).to be_nil
    end

    it "does not apply the target to another bot instance" do
      allow(manager).to receive(:resolve_session).and_return("s")
      expect(manager).not_to receive(:bind_session)
      manager.route_message(adapter, event.merge(channel_instance_id: "other"))
      expect(channel_config.instance(:feishu)["bind_session_id"]).to eq("original")
      expect(channel_config).not_to have_received(:save)
    end

    it "does not silently replace a deleted target with a new conversation" do
      channel_config.instance(:feishu)["bind_session_id"] = "missing"
      expect(manager).not_to receive(:auto_create_session)
      expect(agent).not_to receive(:run)
      expect(adapter).to receive(:send_text).with("chat-1", /no longer exists/)
      manager.route_message(adapter, event)
    end
  end

end
