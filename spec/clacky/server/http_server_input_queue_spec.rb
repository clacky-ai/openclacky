# frozen_string_literal: true
require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "input behavior routing" do
  let(:config) { Clacky::AgentConfig.new }
  let(:registry) { Clacky::Server::SessionRegistry.new(agent_config: config) }
  let(:agent) { double("agent") }
  let(:server) do
    described_class.allocate.tap do |s|
      s.instance_variable_set(:@registry, registry)
      s.instance_variable_set(:@agent_config, config)
    end
  end
  before do
    registry.create(session_id: "s")
    registry.with_session("s") { |s| s[:agent] = agent; s[:status] = :running }
  end

  it "queues an opted-in message without interrupting or spawning another run" do
    expect(agent).to receive(:enqueue_input).with("extra", hash_including(files: [], references_display: []))
    expect(server).not_to receive(:interrupt_session)
    expect(server).not_to receive(:run_agent_task)
    config.input_behavior = "steer"
    server.send(:handle_user_message, "s", "extra")
    expect(registry.get("s")[:status]).to eq(:running)
    expect(registry.current_epoch("s")).to eq(0)
  end

  it "uses the persisted default when the client omits a mode" do
    config.input_behavior = "steer"
    expect(agent).to receive(:enqueue_input)
    expect(server).not_to receive(:interrupt_session)
    server.send(:handle_user_message, "s", "extra")
  end

  describe "sending pending input immediately" do
    let(:entry) { { id: "p1", content: "extra", options: { files: [{ name: "a.pdf" }], reference_contexts: ["context"] } } }

    it "interrupts and runs the original entry without changing the configured mode" do
      config.input_behavior = "steer"
      expect(agent).to receive(:remove_pending_input).with("p1").ordered.and_return(entry)
      expect(server).to receive(:interrupt_session).with("s", reason: :replacement).ordered
      expect(agent).to receive(:run_pending_input).with(entry)
      expect(server).to receive(:run_agent_task).with("s", agent) { |&task| task.call; true }
      expect(agent).not_to receive(:enqueue_input)
      server.send(:send_pending_input, "s", "p1")
      expect(config.input_behavior).to eq("steer")
    end

    it "does not interrupt when the message has already been consumed" do
      expect(agent).to receive(:remove_pending_input).with("p1").and_return(nil)
      expect(server).not_to receive(:interrupt_session)
      expect(server).not_to receive(:run_agent_task)
      server.send(:send_pending_input, "s", "p1")
    end

    it "restores the message if starting the task is rejected" do
      registry.with_session("s") { |s| s[:status] = :idle }
      expect(agent).to receive(:remove_pending_input).with("p1").and_return(entry)
      expect(server).not_to receive(:interrupt_session)
      expect(server).to receive(:run_agent_task).and_return(nil)
      expect(agent).to receive(:enqueue_input).with(entry[:content], **entry[:options])
      server.send(:send_pending_input, "s", "p1")
    end
  end

  it "retains the existing interrupt path by default" do
    expect(server).to receive(:interrupt_session).with("s", reason: :replacement) { throw :interrupted }
    expect(agent).not_to receive(:enqueue_input)
    catch(:interrupted) { server.send(:handle_user_message, "s", "extra") }
  end
end

RSpec.describe Clacky::Server::HttpServer, "queued input during task finalization" do
  let(:config) { Clacky::AgentConfig.new(input_behavior: "steer") }
  let(:registry) { Clacky::Server::SessionRegistry.new(agent_config: config) }
  let(:pending) { { id: "message-1", content: "late guidance", options: {} } }
  let(:agent) { double("agent", to_session_data: {}) }
  let(:server) do
    described_class.allocate.tap do |s|
      s.instance_variable_set(:@registry, registry)
      s.instance_variable_set(:@session_manager, double("sessions", save: nil))
    end
  end

  before do
    registry.create(session_id: "s")
    registry.with_session("s") { |s| s[:agent] = agent }
    allow(registry).to receive(:evict_excess_idle!)
    allow(server).to receive(:broadcast_session_update)
    allow(server).to receive(:broadcast_all)
    allow(server).to receive(:broadcast)
  end

  it "drains late guidance on the same worker before marking idle" do
    allow(agent).to receive(:take_pending_input).and_return(pending, nil)
    expect(agent).to receive(:run_pending_input).with(pending) do
      expect(registry.get("s")[:status]).to eq(:running)
      { status: :success }
    end
    server.send(:run_agent_task, "s", agent) { { status: :success } }
    expect(registry.get("s")[:thread].join(2)).not_to be_nil
    expect(registry.get("s")[:status]).to eq(:idle)
    expect(registry.current_epoch("s")).to eq(1)
  end

  [:user, :replacement].each do |reason|
    it "broadcasts the #{reason} interruption reason from the interrupted worker" do
      ready = Queue.new
      expect(agent).not_to receive(:take_pending_input)
      expect(server).to receive(:broadcast).with("s", hash_including(type: "interrupted", reason: reason))
      worker = server.send(:run_agent_task, "s", agent) do
        ready << true
        Queue.new.pop
      end
      ready.pop
      server.send(:interrupt_session, "s", reason: reason)
      expect(worker.join(2)).not_to be_nil
    ensure
      worker&.kill if worker&.alive?
    end
  end

  it "does not drain queued work after explicit interruption" do
    expect(agent).not_to receive(:take_pending_input)
    server.send(:run_agent_task, "s", agent) { raise Clacky::AgentInterrupted }
    expect(registry.get("s")[:thread].join(2)).not_to be_nil
    expect(registry.get("s")[:status]).to eq(:idle)
  end
end
