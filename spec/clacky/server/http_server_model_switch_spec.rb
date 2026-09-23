# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer, "model switch guards" do
  include HttpServerSpecHelpers

  let(:config) do
    Clacky::AgentConfig.new(models: [
      { "model" => "test-model", "api_key" => "test-key", "base_url" => "https://example.com" }
    ])
  end

  [[:model, :switch_model_by_id], [:submodel, :set_session_sub_model]].each do |endpoint, method|
    describe "PATCH /api/sessions/:id/#{endpoint}" do
      def setup_session(server, status)
        registry = server.instance_variable_get(:@registry)
        registry.create(session_id: "test")
        agent = double("agent", to_session_data: {}, current_model_info: { sub_model: nil })
        registry.update("test", agent: agent, status: status)
        allow(server).to receive(:broadcast_session_update)
        manager = server.instance_variable_get(:@session_manager)
        allow(manager).to receive(:save)
        [registry, agent, manager]
      end

      let(:payload) { endpoint == :model ? { model_id: config.models.first["id"] } : { model_name: nil } }
      let(:request) { fake_req(method: "PATCH", path: "/api/sessions/test/#{endpoint}", body: payload) }

      it "returns 409 without switching, persisting or broadcasting when running" do
        with_server(agent_config: config) do |server|
          _, agent, manager = setup_session(server, :running)
          expect(agent).not_to receive(method)
          expect(manager).not_to receive(:save)
          expect(server).not_to receive(:broadcast_session_update)
          res = fake_res
          dispatch(server, request, res)
          expect(res.status).to eq(409)
          expect(parsed_body(res)["error"]).to include("running")
        end
      end

      [:idle, :awaiting_feedback, :error].each do |status|
        it "allows switching from #{status}" do
          with_server(agent_config: config) do |server|
            _, agent, manager = setup_session(server, status)
            expect(agent).to receive(method).and_return(true)
            expect(manager).to receive(:save)
            res = fake_res
            dispatch(server, request, res)
            expect(res.status).to eq(200)
          end
        end
      end

      it "rejects a worker still alive after its status changed to idle" do
        with_server(agent_config: config) do |server|
          registry, agent, manager = setup_session(server, :idle)
          registry.update("test", thread: double("worker", alive?: true))
          expect(agent).not_to receive(method)
          expect(manager).not_to receive(:save)
          res = fake_res
          dispatch(server, request, res)
          expect(res.status).to eq(409)
        end
      end

      it "holds the startup status lock until the model mutation completes" do
        with_server(agent_config: config) do |server|
          registry, agent, = setup_session(server, :idle)
          entered = Queue.new
          release = Queue.new
          allow(agent).to receive(method) { entered << true; release.pop; true }
          req = request
          res = fake_res
          switch = Thread.new { dispatch(server, req, res) }
          Timeout.timeout(3) { entered.pop }
          startup = Thread.new { registry.update("test", status: :running) }
          expect(startup.join(0.05)).to be_nil
          release << true
          Timeout.timeout(3) { switch.join; startup.join }
          expect(res.status).to eq(200)
          expect(registry.get("test")[:status]).to eq(:running)
        ensure
          [switch, startup].compact.each { |t| t.kill; t.join }
        end
      end
    end
  end
end
