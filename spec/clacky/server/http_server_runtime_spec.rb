# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "clacky/server/http_server"
require "clacky/runtime_session"
require "clacky/agent_runtime_registry"
require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer, "runtime session lifecycle" do
  include HttpServerSpecHelpers

  RuntimeServerSpecProfile = Struct.new(:name) do
    def container_dir
      nil
    end
  end

  class RuntimeServerSpecAdapter
    attr_reader :context, :persisted_state, :runs, :cancel_reasons,
      :selected_models

    def initialize(context:, persisted_state: nil, **_options)
      @context = context
      @persisted_state = persisted_state
      @runs = []
      @cancel_reasons = []
      @selected_models = []
      @selectable_models = nil
      @model_selection_result = true
      @model_selection_busy = false
      @current_model = "codex-current"
      @closed = false
    end

    def capabilities
      capabilities = { cancel: true, image_input: true }
      capabilities[:model_selection] = true if @selectable_models
      capabilities
    end

    def enable_model_selection(*models)
      @selectable_models = models
    end

    def model_options
      Array(@selectable_models)
    end

    def discover_models(working_dir: Dir.pwd)
      {
        ok: true,
        status: "connected",
        authenticated: true,
        default_model: "codex-current",
        models: ["codex-current", "gpt-5.6-sol"],
        working_dir: working_dir
      }
    end

    def reject_model_selection!
      @model_selection_result = false
    end

    def make_model_selection_busy!
      @model_selection_busy = true
    end

    def set_model(model)
      if @model_selection_busy
        raise Clacky::RuntimeSession::BusyError,
              "Runtime model cannot change during an in-flight prompt"
      end
      return false unless @model_selection_result

      @selected_models << model
      @current_model = model
      true
    end

    def run(input, generation:)
      @runs << [input, generation]
      @context[:event_sink].call(
        generation,
        type: :assistant_delta,
        message_id: "assistant-1",
        content: "Runtime reply"
      )
      { stop_reason: "end_turn" }
    end

    def cancel(reason:)
      @cancel_reasons << reason
      true
    end

    def dump_state
      @persisted_state || {
        "session_id" => "external-new",
        "model" => @current_model
      }
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  class BarrierRuntimeServerSpecAdapter < RuntimeServerSpecAdapter
    attr_reader :timeline

    def initialize(**options)
      super
      @timeline = []
      @first_started = Queue.new
      @first_response = Queue.new
    end

    def run(input, generation:)
      @runs << [input, generation]
      @timeline << [:started, input.content]
      if @runs.length == 1
        @first_started << true
        @first_response.pop
        @timeline << [:completed, input.content]
      end
      { stop_reason: "end_turn" }
    end

    def cancel(reason:)
      @cancel_reasons << reason
      @timeline << [:cancelled, reason]
      true
    end

    def wait_until_first_started
      @first_started.pop
    end

    def complete_first_prompt
      @first_response << true
    end
  end

  class TitledRuntimeServerSpecAdapter < RuntimeServerSpecAdapter
    def run(input, generation:)
      @runs << [input, generation]
      @context[:event_sink].call(
        generation,
        type: :session_info,
        title: "Provider generated title"
      )
      { stop_reason: "end_turn", assistant_text: "Done" }
    end
  end

  let(:runtime_config) do
    Clacky::AgentConfig.new(models: [
      {
        "id" => "runtime-card-current",
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "ChatGPT default",
        "type" => "default"
      }
    ])
  end
  let(:runtime_config_dir) { Dir.mktmpdir("clacky_runtime_http_config") }
  let(:runtime_config_file) { File.join(runtime_config_dir, "config.yml") }
  let(:built_runtimes) { [] }
  let(:runtime_factory) do
    lambda do |**options|
      RuntimeServerSpecAdapter.new(**options).tap { |runtime| built_runtimes << runtime }
    end
  end
  let(:runtime_registry) do
    Clacky::AgentRuntimeRegistry.new(
      extension_units: [],
      factories: { "codex" => runtime_factory }
    )
  end
  let(:provider_registry) do
    Clacky::ProviderRegistry.new(
      extension_units: [],
      presets: {
        "codex" => {
          "id" => "codex",
          "name" => "ChatGPT",
          "runtime_id" => "codex",
          "auth_mode" => "runtime",
          "dynamic_models" => "discovery",
          "capabilities" => { "vision" => true }
        }
      }
    )
  end

  before do
    stub_const("Clacky::AgentConfig::CONFIG_FILE", runtime_config_file)
    allow(Clacky::AgentProfile).to receive(:load)
      .and_return(RuntimeServerSpecProfile.new("general"))
  end

  after do
    FileUtils.remove_entry(runtime_config_dir) if File.exist?(runtime_config_dir)
  end

  it "isolates runtime model persistence from the user configuration" do
    expect(Clacky::AgentConfig::CONFIG_FILE).to eq(runtime_config_file)
    expect(runtime_config_file).to start_with(runtime_config_dir)
  end

  def persisted_runtime_session(session_id: "runtime-restored", provider_id: "codex")
    {
      session_id: session_id,
      name: "Restored runtime",
      pinned: false,
      created_at: "2026-09-10T00:00:00Z",
      updated_at: "2026-09-10T00:00:01Z",
      working_dir: Dir.pwd,
      source: "manual",
      agent_profile: "general",
      config: {
        permission_mode: "confirm_all",
        model_id: "runtime-card-from-an-old-process",
        provider_id: provider_id
      },
      runtime: {
        id: "codex",
        version: 1,
        state: {
          "session_id" => "external-restored",
          "model" => "codex-restored"
        }
      },
      stats: { total_tasks: 1, total_cost_usd: 0.0, cost_source: "provider" },
      messages: [
        { role: "user", content: "Earlier question", created_at: 1.0 },
        { role: "assistant", content: "Earlier answer", created_at: 2.0 }
      ]
    }
  end

  it "requires and persists an advertised default model on a runtime card" do
    config = Clacky::AgentConfig.new(models: [
      {
        "id" => "api-card",
        "model" => "api-model",
        "base_url" => "https://api.example.test",
        "api_key" => "secret",
        "type" => "default"
      }
    ])

    with_server(
      agent_config: config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      missing = fake_res
      dispatch(
        server,
        fake_req(
          method: "POST",
          path: "/api/config/models",
          body: { provider_id: "codex" }
        ),
        missing
      )
      expect(missing.status).to eq(422)

      unknown = fake_res
      dispatch(
        server,
        fake_req(
          method: "POST",
          path: "/api/config/models",
          body: { provider_id: "codex", display_model: "not-advertised" }
        ),
        unknown
      )
      expect(unknown.status).to eq(422)

      created_response = fake_res
      dispatch(
        server,
        fake_req(
          method: "POST",
          path: "/api/config/models",
          body: {
            provider_id: "codex",
            display_model: "gpt-5.6-sol",
            type: "default"
          }
        ),
        created_response
      )

      expect(created_response.status).to eq(200)
      created = config.models.find do |model|
        model["id"] == parsed_body(created_response)["id"]
      end
      expect(created).to include(
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "gpt-5.6-sol",
        "type" => "default"
      )
    end
  end

  it "updates a runtime card only to an advertised default model" do
    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      rejected = fake_res
      dispatch(
        server,
        fake_req(
          method: "PATCH",
          path: "/api/config/models/runtime-card-current",
          body: { display_model: "not-advertised", remark: "must not persist" }
        ),
        rejected
      )
      expect(rejected.status).to eq(422)
      expect(runtime_config.current_model).to include(
        "display_model" => "ChatGPT default"
      )
      expect(runtime_config.current_model).not_to have_key("remark")

      updated = fake_res
      dispatch(
        server,
        fake_req(
          method: "PATCH",
          path: "/api/config/models/runtime-card-current",
          body: { display_model: "codex-current" }
        ),
        updated
      )
      expect(updated.status).to eq(200)
      expect(runtime_config.current_model).to include(
        "display_model" => "codex-current"
      )
    end
  end

  it "selects the runtime before constructing an API client" do
    expect(Clacky::Client).not_to receive(:new)

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Codex task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      session = server.instance_variable_get(:@registry).get(session_id)
      agent = session[:agent]

      expect(agent).to be_a(Clacky::RuntimeSession)
      expect(session[:idle_timer]).to be_nil
      expect(built_runtimes.fetch(0).context).to include(
        session_id: session_id,
        working_dir: Dir.pwd
      )
      expect(server.instance_variable_get(:@session_manager).load(session_id))
        .to include(runtime: hash_including(id: "codex"))
    end
  end

  it "uses the live runtime capability and effective model for vision status" do
    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Codex task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      res = fake_res
      dispatch(
        server,
        fake_req(
          method: "GET",
          path: "/api/config",
          query_string: URI.encode_www_form(session_id: session_id)
        ),
        res
      )

      expect(parsed_body(res).dig("media_capabilities", "vision")).to eq(
        "configured" => true,
        "primary" => true,
        "model" => "codex-current"
      )
    end
  end

  it "shows provider-declared runtime vision as primary auto in Settings only" do
    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      ocr_res = fake_res
      dispatch(
        server,
        fake_req(method: "GET", path: "/api/config/ocr"),
        ocr_res
      )

      expect(ocr_res.status).to eq(200)
      expect(parsed_body(ocr_res).fetch("ocr")).to include(
        "configured" => true,
        "source" => "auto",
        "primary" => true,
        "provider" => "codex",
        "model" => "ChatGPT default"
      )

      media_res = fake_res
      dispatch(
        server,
        fake_req(method: "GET", path: "/api/config/media"),
        media_res
      )
      media_defaults = parsed_body(media_res).fetch("default_provider")
      media = parsed_body(media_res).fetch("media")
      %w[image video audio stt video_understanding].each do |kind|
        expect(media_defaults.fetch(kind)).to include("model" => nil)
        expect(media.fetch(kind)).to include(
          "configured" => false,
          "source" => "off",
          "model" => nil
        )
      end
    end
  end

  it "preserves a custom OCR sidecar when the runtime also declares vision" do
    custom_config = Clacky::AgentConfig.new(models: runtime_config.models + [
      {
        "id" => "custom-ocr",
        "type" => "ocr",
        "mode" => "custom",
        "model" => "custom-vision",
        "base_url" => "https://vision.example.test/v1",
        "api_key" => "secret-vision-key"
      }
    ])

    with_server(
      agent_config: custom_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      res = fake_res
      dispatch(server, fake_req(method: "GET", path: "/api/config/ocr"), res)

      expect(parsed_body(res).fetch("ocr")).to include(
        "configured" => true,
        "source" => "custom",
        "primary" => false,
        "model" => "custom-vision",
        "base_url" => "https://vision.example.test/v1"
      )
      expect(parsed_body(res).dig("ocr", "api_key_masked")).to include("****")
      expect(custom_config.models.map { |model| model["id"] }).to include("custom-ocr")
    end
  end

  it "keeps Visual Understanding off when a runtime does not declare vision" do
    no_vision_registry = Clacky::ProviderRegistry.new(
      extension_units: [],
      presets: {
        "codex" => {
          "id" => "codex",
          "name" => "ChatGPT",
          "runtime_id" => "codex",
          "auth_mode" => "runtime",
          "display_model" => "ChatGPT default",
          "capabilities" => { "vision" => false }
        }
      }
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: no_vision_registry,
      runtime_registry: runtime_registry
    ) do |server|
      res = fake_res
      dispatch(server, fake_req(method: "GET", path: "/api/config/ocr"), res)

      expect(parsed_body(res).fetch("ocr")).to include(
        "configured" => false,
        "source" => "off",
        "primary" => false,
        "model" => nil
      )
    end
  end

  it "switches a runtime-native model through the existing session endpoint" do
    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Codex task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      runtime = built_runtimes.fetch(0)
      runtime.enable_model_selection("codex-current", "gpt-5.6-sol")
      expect(server).to receive(:broadcast_session_update).with(session_id)
      res = fake_res

      server.send(
        :api_switch_session_submodel,
        session_id,
        fake_req(
          method: "PATCH",
          path: "",
          body: { model_name: "gpt-5.6-sol" }
        ),
        res
      )

      expect(res.status).to eq(200)
      expect(parsed_body(res)).to include(
        "ok" => true,
        "sub_model" => "gpt-5.6-sol"
      )
      expect(runtime.selected_models).to eq(["gpt-5.6-sol"])
      expect(server.instance_variable_get(:@session_manager).load(session_id))
        .to include(runtime: hash_including(
          state: hash_including(model: "gpt-5.6-sol")
        ))
    end
  end

  it "rejects a model not advertised by the runtime" do
    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Codex task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      runtime = built_runtimes.fetch(0)
      runtime.enable_model_selection("codex-current", "gpt-5.6-sol")
      res = fake_res

      server.send(
        :api_switch_session_submodel,
        session_id,
        fake_req(
          method: "PATCH",
          path: "",
          body: { model_name: "unadvertised-model" }
        ),
        res
      )

      expect(res.status).to eq(400)
      expect(parsed_body(res)["error"]).to match(/advertised|available/i)
      expect(runtime.selected_models).to be_empty
    end
  end

  it "returns conflict when a runtime becomes busy during model selection" do
    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Codex task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      runtime = built_runtimes.fetch(0)
      runtime.enable_model_selection("codex-current", "gpt-5.6-sol")
      runtime.make_model_selection_busy!
      expect(server).not_to receive(:broadcast_session_update)
      expect(server.instance_variable_get(:@session_manager)).not_to receive(:save)
      res = fake_res

      server.send(
        :api_switch_session_submodel,
        session_id,
        fake_req(
          method: "PATCH",
          path: "",
          body: { model_name: "gpt-5.6-sol" }
        ),
        res
      )

      expect(res.status).to eq(409)
      expect(parsed_body(res)["error"]).to match(/in-flight prompt/i)
      expect(runtime.selected_models).to be_empty
    end
  end

  it "does not persist or broadcast a rejected runtime model selection" do
    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Codex task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      runtime = built_runtimes.fetch(0)
      runtime.enable_model_selection("codex-current", "gpt-5.6-sol")
      runtime.reject_model_selection!
      expect(server).not_to receive(:broadcast_session_update)
      expect(server.instance_variable_get(:@session_manager)).not_to receive(:save)
      res = fake_res

      server.send(
        :api_switch_session_submodel,
        session_id,
        fake_req(
          method: "PATCH",
          path: "",
          body: { model_name: "gpt-5.6-sol" }
        ),
        res
      )

      expect(res.status).to eq(500)
      expect(parsed_body(res)["error"]).to match(/failed.*model/i)
      expect(runtime.selected_models).to be_empty
    end
  end

  it "restores an API session on its saved API card when Codex is now the default" do
    config = Clacky::AgentConfig.new(models: [
      {
        "id" => "api-card",
        "provider_id" => "custom",
        "model" => "saved-api-model",
        "base_url" => "https://api.example.test",
        "api_key" => "saved-secret"
      },
      {
        "id" => "runtime-card-current",
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "Codex default",
        "type" => "default"
      }
    ])
    data = {
      session_id: "api-restored",
      name: "Restored API",
      created_at: "2026-09-10T00:00:00Z",
      updated_at: "2026-09-10T00:00:01Z",
      working_dir: Dir.pwd,
      source: "manual",
      agent_profile: "general",
      config: {
        model_name: "saved-api-model",
        model_base_url: "https://api.example.test"
      },
      stats: {},
      messages: []
    }
    fake_agent = double("restored API agent")

    with_server(
      agent_config: config,
      client_factory: -> { raise "global runtime default must not build the restore client" },
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      allow(server).to receive(:build_idle_timer).and_return(:idle_timer)
      expect(Clacky::Client).to receive(:new).with(
        "saved-secret",
        hash_including(
          base_url: "https://api.example.test",
          model: "saved-api-model",
          provider_id: nil
        )
      ).and_return(double("api client"))
      expect(Clacky::Agent).to receive(:from_session) do |_client, restored_config, *_args|
        expect(restored_config.current_model["id"]).to eq("api-card")
        fake_agent
      end

      session_id = server.send(:build_session_from_data, data)
      restored = server.instance_variable_get(:@registry).get(session_id)
      expect(restored[:agent]).to equal(fake_agent)
      expect(restored[:idle_timer]).to eq(:idle_timer)
    end
  end

  it "keeps a legacy API transcript readable when only runtime cards remain" do
    data = persisted_runtime_session(session_id: "removed-api-restored")
    data.delete(:runtime)
    data[:config] = {
      permission_mode: "confirm_all",
      model_name: "removed-api-model",
      model_base_url: "https://removed-api.example.test"
    }

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      expect(Clacky::Client).to receive(:new).with(
        nil,
        hash_including(
          base_url: "https://removed-api.example.test",
          model: "removed-api-model"
        )
      ).at_least(:once).and_call_original

      session_id = server.send(:build_session_from_data, data)
      restored = server.instance_variable_get(:@registry).get(session_id)[:agent]
      expect(restored).to be_a(Clacky::Agent)
      expect(restored.current_model_info).to include(
        model: "removed-api-model",
        base_url: "https://removed-api.example.test"
      )
      expect(restored.current_model_info).not_to include(runtime_id: "codex")

      res = fake_res
      server.send(
        :api_session_messages,
        session_id,
        fake_req(method: "GET", path: ""),
        res
      )
      expect(res.status).to eq(200)
      expect(parsed_body(res)["events"].map { |event| event["content"] })
        .to eq(["Earlier question", "Earlier answer"])
    end
  end

  it "restores by stable runtime and provider identity without provider-history replay" do
    config = Clacky::AgentConfig.new(models: [
      {
        "id" => "other-provider-card",
        "provider_id" => "other",
        "runtime_id" => "codex",
        "display_model" => "Other runtime",
        "type" => "default"
      },
      {
        "id" => "runtime-card-regenerated",
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "Codex default"
      }
    ])
    client_factory = lambda { raise "API client must not be built" }

    with_server(
      agent_config: config,
      client_factory: client_factory,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      data = persisted_runtime_session
      session_id = server.send(:build_session_from_data, data)
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]

      expect(agent).to be_a(Clacky::RuntimeSession)
      expect(agent.current_model_info).to include(
        id: "runtime-card-regenerated",
        provider_id: "codex",
        runtime_id: "codex"
      )
      expect(built_runtimes.fetch(0).persisted_state).to eq(data[:runtime][:state])
      expect(built_runtimes.fetch(0).runs).to be_empty

      req = fake_req(method: "GET", path: "/api/sessions/#{session_id}/messages")
      res = fake_res
      server.send(:api_session_messages, session_id, req, res)

      expect(res.status).to eq(200)
      expect(parsed_body(res)["events"].map { |event| event["content"] })
        .to eq(["Earlier question", "Earlier answer"])
      expect(built_runtimes.fetch(0).runs).to be_empty
    end
  end

  it "returns the restored session-owned runtime model when its global card is gone" do
    config = Clacky::AgentConfig.new(models: [{
      "id" => "api-card",
      "model" => "api-model",
      "base_url" => "https://api.example.test",
      "api_key" => "secret"
    }])

    with_server(
      agent_config: config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(:build_session_from_data, persisted_runtime_session)
      built_runtimes.fetch(0).enable_model_selection(
        "codex-restored", "gpt-5.6-sol"
      )
      res = fake_res

      server.send(
        :api_get_config,
        fake_req(
          method: "GET",
          path: "/api/config",
          query_string: "session_id=#{session_id}"
        ),
        res
      )

      expect(res.status).to eq(200)
      body = parsed_body(res)
      expect(body["models"].map { |model| model["id"] }).to eq(["api-card"])
      expect(body["session_model"]).to include(
        "id" => "restored-runtime:codex:codex",
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "model" => "codex-restored",
        "sub_model" => "codex-restored",
        "sub_model_options" => ["codex-restored", "gpt-5.6-sol"]
      )
    end
  end

  it "paginates runtime history after saving and restoring a session" do
    saved = nil
    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime history",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      agent.run("First question", created_at: 1.0)
      agent.run("Second question", created_at: 3.0)
      saved = agent.to_session_data(updated_at: Time.now)
    end

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(:build_session_from_data, saved)
      req = fake_req(
        method: "GET",
        path: "/api/sessions/#{session_id}/messages",
        query_string: "window=1&limit=1"
      )
      res = fake_res

      server.send(:api_session_messages, session_id, req, res)

      body = parsed_body(res)
      expect(res.status).to eq(200)
      expect(body["events"].map { |event| event["content"] })
        .to eq(["Second question", "Runtime reply"])
      expect(body).to include("has_more" => true, "has_after" => false)
      expect(body["before_cursor"]).to eq(body["events"].first["round_id"])
      expect(body["after_cursor"]).to eq(body["events"].first["round_id"])
    end
  end

  it "preserves runtime tool ids when replaying the persisted transcript" do
    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      data = persisted_runtime_session
      data[:messages] = [
        { role: "user", content: "Run it", created_at: 1.0 },
        {
          role: "assistant",
          content: nil,
          tool_calls: [{
            id: "tool-replay",
            type: "function",
            function: { name: "terminal", arguments: '{"command":"pwd"}' }
          }]
        },
        {
          role: "tool",
          tool_call_id: "tool-replay",
          content: "/workspace"
        },
        { role: "assistant", content: "Done", created_at: 2.0 }
      ]
      session_id = server.send(:build_session_from_data, data)
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      expect(agent.history.to_a.map { |message| message[:role] })
        .to eq(%w[user assistant tool assistant])
      res = fake_res

      server.send(
        :api_session_messages,
        session_id,
        fake_req(method: "GET", path: ""),
        res
      )

      events = parsed_body(res)["events"]
      expect(events.find { |event| event["type"] == "tool_call" })
        .to include("tool_call_id" => "tool-replay")
      expect(events.find { |event| event["type"] == "tool_result" })
        .to include("tool_call_id" => "tool-replay")
    end
  end

  it "keeps a restored transcript readable when its runtime is unavailable" do
    unavailable_registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [],
      factories: {}
    )
    client_factory = lambda { raise "API client must not be built" }

    with_server(
      agent_config: runtime_config,
      client_factory: client_factory,
      provider_registry: provider_registry,
      runtime_registry: unavailable_registry
    ) do |server|
      session_id = server.send(:build_session_from_data, persisted_runtime_session)
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      req = fake_req(method: "GET", path: "/api/sessions/#{session_id}/messages")
      res = fake_res

      server.send(:api_session_messages, session_id, req, res)

      expect(agent).to be_a(Clacky::RuntimeSession)
      expect(res.status).to eq(200)
      expect(parsed_body(res)["events"].map { |event| event["content"] })
        .to eq(["Earlier question", "Earlier answer"])
      expect(agent.to_session_data[:runtime][:state]).to include(
        "session_id" => "external-restored"
      )
    end
  end

  it "rejects a new session whose saved runtime provider is unavailable" do
    unavailable_registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [], factories: {}
    )

    with_server(
      agent_config: runtime_config,
      client_factory: lambda { raise "API client must not be built" },
      provider_registry: provider_registry,
      runtime_registry: unavailable_registry
    ) do |server|
      res = fake_res
      server.send(
        :api_create_session,
        fake_req(
          method: "POST",
          path: "/api/sessions",
          body: { name: "Unavailable", model_id: "runtime-card-current" }
        ),
        res
      )

      expect(res.status).to eq(422)
      expect(parsed_body(res)["error"]).to match(/runtime.*unavailable/i)
      expect(server.instance_variable_get(:@registry).exist?("Unavailable")).to be(false)
    end
  end

  it "keeps startup alive with a readable placeholder for an unavailable default runtime" do
    unavailable_registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [], factories: {}
    )

    with_server(
      agent_config: runtime_config,
      client_factory: lambda { raise "API client must not be built" },
      provider_registry: provider_registry,
      runtime_registry: unavailable_registry
    ) do |server|
      expect { server.send(:create_default_session) }.not_to raise_error
      live = []
      server.instance_variable_get(:@registry).each_live_agent do |_id, agent, _thread|
        live << agent
      end
      expect(live.length).to eq(1)
      expect { live.first.run("hello") }.to raise_error(/unavailable/i)
    end
  end

  %i[cron channel].each do |source|
    it "rejects the runtime provider for #{source} sessions in v1" do
      with_server(
        agent_config: runtime_config,
        provider_registry: provider_registry,
        runtime_registry: runtime_registry
      ) do |server|
        expect do
          server.send(
            :build_session,
            name: source.to_s,
            working_dir: Dir.pwd,
            source: source,
            model_id: "runtime-card-current"
          )
        end.to raise_error(ArgumentError, /manual.*session/i)
      end
    end
  end

  it "marks run-now cron sessions as cron so the runtime guard cannot be bypassed" do
    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      scheduler = server.instance_variable_get(:@scheduler)
      allow(scheduler).to receive(:list_tasks).and_return(["nightly"])
      allow(scheduler).to receive(:read_task).with("nightly").and_return("do work")
      res = fake_res

      server.send(:api_run_cron_task, "nightly", res)

      expect(res.status).to eq(422)
      expect(parsed_body(res)["error"]).to match(/manual.*session/i)
      expect(built_runtimes).to be_empty
    end
  end

  it "keeps a restored transcript readable when the registered adapter fails to load" do
    broken_registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [],
      factories: { "codex" => lambda { |**_options| raise LoadError, "broken" } }
    )
    client_factory = lambda { raise "API client must not be built" }

    with_server(
      agent_config: runtime_config,
      client_factory: client_factory,
      provider_registry: provider_registry,
      runtime_registry: broken_registry
    ) do |server|
      data = persisted_runtime_session
      session_id = server.send(:build_session_from_data, data)
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      res = fake_res

      server.send(
        :api_session_messages,
        session_id,
        fake_req(method: "GET", path: ""),
        res
      )

      expect(agent).to be_a(Clacky::RuntimeSession)
      expect(res.status).to eq(200)
      expect(parsed_body(res)["events"].map { |event| event["content"] })
        .to eq(["Earlier question", "Earlier answer"])
      expect(agent.to_session_data[:runtime][:state])
        .to include("session_id" => "external-restored")
    end
  end

  it "uses the existing supervisor as the runtime generation and persistence boundary" do
    expect(Clacky::Client).not_to receive(:new)

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      registry = server.instance_variable_get(:@registry)
      agent = registry.get(session_id)[:agent]
      allow(registry).to receive(:evict_excess_idle!)

      worker = server.send(:run_agent_task, session_id, agent) { agent.run("Hello") }

      expect(worker.join(2)).not_to be_nil
      expect(built_runtimes.fetch(0).runs.fetch(0).last).to eq(1)
      expect(registry.get(session_id)).to include(status: :idle, idle_timer: nil)
      saved = server.instance_variable_get(:@session_manager).load(session_id)
      expect(saved.dig(:stats, :last_status)).to eq("success")
      expect(saved.dig(:runtime, :id)).to eq("codex")
    end
  end

  it "lets a provider title replace only the first-message autogenerated name" do
    titled_runtimes = []
    titled_registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [],
      factories: {
        "codex" => lambda do |**options|
          TitledRuntimeServerSpecAdapter.new(**options).tap do |runtime|
            titled_runtimes << runtime
          end
        end
      }
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: titled_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Session 1",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )

      worker = server.send(:handle_user_message, session_id, "First prompt")
      expect(worker.join(2)).not_to be_nil

      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      expect(titled_runtimes.fetch(0).runs.length).to eq(1)
      expect(agent.name).to eq("Provider generated title")
      expect(server.instance_variable_get(:@session_manager).load(session_id)[:name])
        .to eq("Provider generated title")
    end
  end

  it "cancels a running ACP turn and drains its replacement only after the prompt response" do
    barrier_runtimes = []
    barrier_factory = lambda do |**options|
      BarrierRuntimeServerSpecAdapter.new(**options).tap do |runtime|
        barrier_runtimes << runtime
      end
    end
    registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [], factories: { "codex" => barrier_factory }
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      runtime = barrier_runtimes.fetch(0)
      worker = server.send(:run_agent_task, session_id, agent) { agent.run("first") }
      runtime.wait_until_first_started

      server.send(:handle_user_message, session_id, "second")

      expect(runtime.cancel_reasons).to eq([:replacement])
      expect(runtime.runs.map { |input, _generation| input.content }).to eq(["first"])
      expect(worker).to be_alive

      runtime.complete_first_prompt
      expect(worker.join(2)).not_to be_nil
      expect(runtime.runs.map { |input, _generation| input.content })
        .to eq(["first", "second"])
      expect(runtime.timeline).to eq([
        [:started, "first"],
        [:cancelled, :replacement],
        [:completed, "first"],
        [:started, "second"]
      ])
    ensure
      runtime&.complete_first_prompt if worker&.alive?
      worker&.join(1)
    end
  end

  it "does not append the optimistic interrupt message again when the runtime drains it" do
    barrier_runtimes = []
    registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [],
      factories: {
        "codex" => lambda do |**options|
          BarrierRuntimeServerSpecAdapter.new(**options).tap do |runtime|
            barrier_runtimes << runtime
          end
        end
      }
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      session = server.instance_variable_get(:@registry).get(session_id)
      agent = session[:agent]
      web_ui = session[:ui]
      runtime = barrier_runtimes.fetch(0)
      allow(web_ui).to receive(:show_user_message)
      worker = server.send(:run_agent_task, session_id, agent) { agent.run("first") }
      runtime.wait_until_first_started

      server.send(:handle_user_message, session_id, "second")
      runtime.complete_first_prompt
      expect(worker.join(2)).not_to be_nil

      expect(web_ui).to have_received(:show_user_message).once.with(
        "second",
        hash_including(source: :web, steering: false)
      )
      expect(runtime.runs.map { |input, _generation| input.content })
        .to eq(["first", "second"])
    ensure
      runtime&.complete_first_prompt if worker&.alive?
      worker&.join(1)
    end
  end

  it "atomically queues two runtime messages that both observed an idle session" do
    barrier_runtimes = []
    registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [],
      factories: {
        "codex" => lambda do |**options|
          BarrierRuntimeServerSpecAdapter.new(**options).tap do |runtime|
            barrier_runtimes << runtime
          end
        end
      }
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Session 1",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      session_registry = server.instance_variable_get(:@registry)
      runtime = barrier_runtimes.fetch(0)
      arrivals = Queue.new
      release = [Queue.new, Queue.new]
      allow(session_registry).to receive(:get).and_wrap_original do |original, id|
        snapshot = original.call(id)
        index = Thread.current[:runtime_race_index]
        if id == session_id && index && !Thread.current[:runtime_race_synced]
          Thread.current[:runtime_race_synced] = true
          arrivals << index
          release.fetch(index).pop
        end
        snapshot
      end

      callers = ["first", "second"].each_with_index.map do |message, index|
        Thread.new do
          Thread.current[:runtime_race_index] = index
          server.send(:handle_user_message, session_id, message)
        end
      end
      expect(arrivals.pop).to eq(0)
      expect(arrivals.pop).to eq(1)

      release.fetch(0) << true
      first_worker = callers.fetch(0).value
      runtime.wait_until_first_started
      release.fetch(1) << true
      second_worker = callers.fetch(1).value
      second_worker&.join(1)

      expect(runtime.runs.map { |input, _generation| input.content }).to eq(["first"])

      runtime.complete_first_prompt
      expect(first_worker.join(2)).not_to be_nil
      expect(runtime.runs.map { |input, _generation| input.content })
        .to eq(["first", "second"])
      agent = session_registry.get(session_id)[:agent]
      expect(agent.history.to_a.select { |message| message[:role] == "user" }
        .map { |message| message[:content] }).to eq(["first", "second"])
      expect(session_registry.get(session_id)).to include(status: :idle, epoch: 1)
    ensure
      release&.each { |queue| queue << true }
      runtime&.complete_first_prompt if first_worker&.alive?
      callers&.each { |thread| thread.join(1) }
      first_worker&.join(1)
      second_worker&.join(1)
    end
  end

  it "keeps an explicitly cancelled runtime worker alive until the ACP response barrier" do
    barrier_runtimes = []
    barrier_factory = lambda do |**options|
      BarrierRuntimeServerSpecAdapter.new(**options).tap do |runtime|
        barrier_runtimes << runtime
      end
    end
    registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [], factories: { "codex" => barrier_factory }
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      runtime = barrier_runtimes.fetch(0)
      worker = server.send(:run_agent_task, session_id, agent) { agent.run("first") }
      runtime.wait_until_first_started

      server.send(:interrupt_session, session_id, reason: :user)

      expect(runtime.cancel_reasons).to eq([:user])
      expect(worker).to be_alive
      runtime.complete_first_prompt
      expect(worker.join(2)).not_to be_nil
      expect(server.instance_variable_get(:@registry).get(session_id)[:status])
        .to eq(:idle)
      expect(server.instance_variable_get(:@session_manager).load(session_id)
        .dig(:stats, :last_status)).to eq("interrupted")
    ensure
      runtime&.complete_first_prompt if worker&.alive?
      worker&.join(1)
    end
  end

  it "rejects fork instead of copying an external runtime session id" do
    expect(Clacky::Client).not_to receive(:new)

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      res = fake_res

      server.send(:api_fork_session, session_id, fake_req(method: "POST", path: ""), res)

      expect(res.status).to eq(409)
      expect(parsed_body(res)["error"]).to match(/runtime/i)
      expect(server.instance_variable_get(:@session_manager).all_sessions.length).to eq(1)
    end
  end

  it "returns explicit capability errors for agent-only session APIs" do
    runtime_config.models << {
      "id" => "api-card",
      "provider_id" => "custom",
      "model" => "api-model",
      "base_url" => "https://example.test",
      "api_key" => "secret"
    }

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )

      checks = [
        [:api_session_skills, [session_id]],
        [:api_session_time_machine, [session_id]],
        [:api_session_messages, [session_id, fake_req(
          method: "GET", path: "", query_string: "navigation=1"
        )]],
        [:api_switch_session_model, [session_id, fake_req(
          method: "PATCH", path: "", body: { model_id: "api-card" }
        )]],
        [:api_change_session_working_dir, [session_id, fake_req(
          method: "PATCH", path: "", body: { working_dir: Dir.pwd }
        )]]
      ]

      checks.each do |method_name, arguments|
        res = fake_res
        server.send(method_name, *arguments, res)
        expect(res.status).to eq(409), method_name.to_s
        expect(parsed_body(res)["error"]).to match(/not support|unavailable/i)
      end
    end
  end

  it "rejects switching an API session onto a runtime provider card" do
    runtime_config.models.unshift(
      "id" => "api-card",
      "provider_id" => "custom",
      "model" => "api-model",
      "base_url" => "https://example.test",
      "api_key" => "secret"
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "API task",
        working_dir: Dir.pwd,
        model_id: "api-card"
      )
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      res = fake_res

      server.send(
        :api_switch_session_model,
        session_id,
        fake_req(method: "PATCH", path: "", body: { model_id: "runtime-card-current" }),
        res
      )

      expect(res.status).to eq(409)
      expect(parsed_body(res)["error"]).to match(/new session|runtime/i)
      expect(agent.current_model_info[:id]).to eq("api-card")
    end
  end

  it "rejects deleting a model card used by a live runtime session" do
    runtime_config.models << {
      "id" => "api-card",
      "provider_id" => "custom",
      "model" => "api-model",
      "base_url" => "https://example.test",
      "api_key" => "secret"
    }

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      res = fake_res

      server.send(:api_delete_model, "runtime-card-current", res)

      expect(res.status).to eq(409)
      expect(parsed_body(res)["error"]).to match(/session|in use/i)
      expect(runtime_config.models.map { |model| model["id"] })
        .to include("runtime-card-current")
      expect(server.instance_variable_get(:@registry).get(session_id)[:agent]
        .current_model_info[:id]).to eq("runtime-card-current")
    end
  end

  it "rejects assigning a runtime provider identity to an API model card" do
    runtime_config.models.unshift(
      "id" => "api-card",
      "provider_id" => "custom",
      "model" => "api-model",
      "base_url" => "https://example.test",
      "api_key" => "secret"
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      req = fake_req(
        method: "PATCH",
        path: "/api/config/models/api-card",
        body: { provider_id: "codex" }
      )
      res = fake_res

      server.send(:api_update_model, "api-card", req, res)

      expect(res.status).to eq(422)
      expect(parsed_body(res)["error"]).to match(/runtime/i)
      expect(runtime_config.models.find { |model| model["id"] == "api-card" })
        .to include("provider_id" => "custom", "model" => "api-model")
    end
  end

  it "returns model and runtime identity in a newly-created session summary" do
    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      req = fake_req(
        method: "POST",
        path: "/api/sessions",
        body: { name: "Runtime task", model_id: "runtime-card-current" }
      )
      res = fake_res

      server.send(:api_create_session, req, res)

      expect(res.status).to eq(201)
      expect(parsed_body(res).fetch("session")).to include(
        "model_id" => "runtime-card-current",
        "runtime_id" => "codex"
      )
    end
  end

  it "excludes runtime provider cards from API model benchmarks" do
    runtime_config.models.unshift(
      "id" => "api-card",
      "provider_id" => "custom",
      "model" => "api-model",
      "base_url" => "https://example.test",
      "api_key" => "secret"
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "API task",
        working_dir: Dir.pwd,
        model_id: "api-card"
      )
      allow(server).to receive(:benchmark_single_model) do |entry, _timeout|
        { model_id: entry["id"], model: entry["model"], ok: true }
      end
      res = fake_res

      server.send(
        :api_benchmark_session_models,
        session_id,
        fake_req(method: "POST", path: ""),
        res
      )

      expect(res.status).to eq(200)
      expect(parsed_body(res)["results"].map { |row| row["model_id"] }).to eq(["api-card"])
    end
  end

  it "closes the runtime when its live session is deleted" do
    expect(Clacky::Client).not_to receive(:new)

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      runtime = built_runtimes.fetch(0)
      res = fake_res

      server.send(:api_delete_session, session_id, res)

      expect(res.status).to eq(200)
      expect(runtime.closed?).to be(true)
    end
  end

  it "closes idle runtime sessions during server shutdown" do
    expect(Clacky::Client).not_to receive(:new)

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      runtime = built_runtimes.fetch(0)

      server.send(:interrupt_all_agents)

      expect(runtime.closed?).to be(true)
    end
  end
end
