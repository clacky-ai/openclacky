# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"

RSpec.describe Clacky::Channel::ChannelManager, "route_message input behavior" do
  let(:registry) { Clacky::Server::SessionRegistry.new(agent_config: Clacky::AgentConfig.new) }
  let(:agent) { double("agent") }
  let(:adapter) { double("adapter", platform_id: :feishu) }
  let(:interrupts) { [] }
  let(:runs) { [] }
  let(:channel_config) do
    double("channel_config", status_messages_enabled?: false, process_messages_enabled?: false)
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
end
