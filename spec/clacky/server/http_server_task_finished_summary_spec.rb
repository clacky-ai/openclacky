# frozen_string_literal: true
require "spec_helper"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "task_finished summary" do
  let(:config) { Clacky::AgentConfig.new }
  let(:registry) { Clacky::Server::SessionRegistry.new(agent_config: config) }
  let(:agent) { double("agent", to_session_data: {}) }
  let(:ui) { Clacky::Server::WebUIController.new("s", ->(_sid, _event) {}) }
  let(:finished) { [] }
  let(:server) do
    described_class.allocate.tap do |s|
      s.instance_variable_set(:@registry, registry)
      s.instance_variable_set(:@session_manager, double("sessions", save: nil))
    end
  end

  before do
    registry.create(session_id: "s")
    registry.with_session("s") { |s| s[:agent] = agent; s[:ui] = ui }
    allow(registry).to receive(:evict_excess_idle!)
    allow(agent).to receive(:take_pending_input)
    allow(server).to receive(:broadcast_session_update)
    allow(server).to receive(:broadcast_all) { |event| finished << event }
  end

  def run(result)
    server.send(:run_agent_task, "s", agent) { result }
    expect(registry.get("s")[:thread].join(2)).not_to be_nil
    finished.last
  end

  it "carries the turn's complete payload to every client" do
    ui.show_complete(iterations: 2, cost: 0.5, duration: 1.5, cost_source: :api, task_id: 7)
    event = run(status: :success, task_id: 7)
    expect(event).to include(type: "task_finished", session_id: "s")
    expect(event[:complete]).to include(iterations: 2, cost: 0.5, duration: 1.5, cost_source: "api", task_id: 7)
  end

  it "omits a summary left over from an earlier turn" do
    ui.show_complete(iterations: 2, cost: 0.5, task_id: 7)
    expect(run(status: :success, task_id: 8)).not_to have_key(:complete)
  end

  it "omits the summary when the turn printed none" do
    expect(run(status: :success)).not_to have_key(:complete)
  end
end
