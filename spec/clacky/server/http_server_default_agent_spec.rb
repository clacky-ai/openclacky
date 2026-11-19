# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

RSpec.describe Clacky::Server::HttpServer, "default agent" do
  DefaultAgentSpecRes = Struct.new(:status, :content_type, :body, :headers) do
    def initialize
      super
      self.headers = {}
    end

    def [](key)
      headers[key]
    end
    def []=(key, value)
      headers[key] = value
    end
  end

  DefaultAgentSpecSentinel = Class.new(StandardError)

  let(:tmpdir) { Dir.mktmpdir("clacky_default_agent_spec") }
  let(:config) { Clacky::AgentConfig.new(models: [{ "model" => "m", "api_key" => "k", "base_url" => "http://x", "type" => "default" }]) }
  let(:server) do
    described_class.new(
      host: "127.0.0.1", port: 0, agent_config: config,
      client_factory: -> { double("client") },
      sessions_dir: File.join(tmpdir, "sessions")
    )
  end
  let(:agents) do
    [
      { id: "general", hidden: false },
      { id: "coding", hidden: false },
      { id: "knowledge", hidden: false },
      { id: "advisor", hidden: true }
    ]
  end

  before do
    allow(Clacky::AgentProfile).to receive(:all).and_return(agents)
    allow(config).to receive(:save)
  end
  after { FileUtils.rm_rf(tmpdir) }

  def call(method, body = nil)
    res = DefaultAgentSpecRes.new
    if body
      server.send(method, Struct.new(:body).new(JSON.generate(body)), res)
    else
      server.send(method, res)
    end
    [res.status, JSON.parse(res.body)]
  end

  describe "settings" do
    it "reads and saves the default agent" do
      expect(call(:api_get_settings)[1]["default_agent"]).to eq("general")

      status, = call(:api_update_settings, "default_agent" => "knowledge")
      expect(status).to eq(200)
      expect(config.default_agent).to eq("knowledge")
      expect(config).to have_received(:save)
      expect(call(:api_get_settings)[1]["default_agent"]).to eq("knowledge")
    end

    it "rejects unknown and hidden agents without changing anything" do
      %w[nope advisor].each do |id|
        status, body = call(:api_update_settings, "default_agent" => id, "memory_inject_enabled" => true)
        expect(status).to eq(422)
        expect(body["error"]).to include(id)
      end
      expect(config.default_agent).to eq("general")
      expect(config.memory_inject_enabled).to be(false)
    end

    it "is reported by the agent list" do
      config.default_agent = "coding"
      allow(server).to receive(:agent_last_used_recency).and_return({})
      expect(call(:api_list_agents)[1]["default_agent"]).to eq("coding")
    end
  end

  describe "fallback" do
    it "uses general when the configured agent is no longer installed" do
      config.default_agent = "uninstalled"
      expect(server.send(:resolved_default_agent)).to eq("general")
      expect(call(:api_get_settings)[1]["default_agent"]).to eq("general")
    end
  end

  describe "session creation" do
    def profile_used
      captured = nil
      allow(Clacky::Agent).to receive(:new) { |*_, **kw| captured = kw[:profile]; raise DefaultAgentSpecSentinel }
      expect { yield }.to raise_error(DefaultAgentSpecSentinel)
      captured
    end

    before { config.default_agent = "knowledge" }

    it "applies the default agent when no profile is given (manual, channel)" do
      expect(profile_used { server.send(:build_session, name: "Session 1", working_dir: tmpdir) }).to eq("knowledge")
      expect(profile_used { server.send(:build_session, name: "weixin-1", working_dir: tmpdir, source: :channel) }).to eq("knowledge")
    end

    it "keeps an explicit profile" do
      expect(profile_used { server.send(:build_session, name: "s", working_dir: tmpdir, profile: "coding") }).to eq("coding")
    end

    it "always runs setup, skill and cron sessions as the general agent" do
      # /onboard, /browser-setup and /channel-manager install something; skill
      # sessions run helper commands such as /cron-task-creator; cron sessions
      # fire unattended. None of them may inherit a restricted default agent
      # (e.g. a knowledge-base agent with a tools whitelist).
      %i[setup skill cron].each do |src|
        expect(
          profile_used { server.send(:build_session, name: "s", working_dir: tmpdir, source: src) }
        ).to eq("general"), "expected #{src} sessions to use the general agent"
      end
    end

    it "still honours an explicit profile on a setup session" do
      expect(
        profile_used { server.send(:build_session, name: "s", working_dir: tmpdir, source: :setup, profile: "coding") }
      ).to eq("coding")
    end

    it "passes the source through from POST /api/sessions" do
      captured = nil
      allow(server).to receive(:build_session) { |**kw| captured = kw[:source]; "sid" }
      allow(server).to receive(:broadcast_session_update)
      allow(server.instance_variable_get(:@registry)).to receive(:session_summary).and_return({ id: "sid" })

      status, = call(:api_create_session, "name" => "Session 1", "source" => "skill", "working_dir" => tmpdir)
      expect(status).to eq(201)
      expect(captured).to eq(:skill)
    end

    it "degrades an unknown source to manual" do
      # A stale value such as the old "onboard" must not silently become a
      # session type of its own.
      captured = nil
      allow(server).to receive(:build_session) { |**kw| captured = kw[:source]; "sid" }
      allow(server).to receive(:broadcast_session_update)
      allow(server.instance_variable_get(:@registry)).to receive(:session_summary).and_return({ id: "sid" })

      call(:api_create_session, "name" => "Memories", "source" => "onboard", "working_dir" => tmpdir)
      expect(captured).to eq(:manual)
    end
  end
end
