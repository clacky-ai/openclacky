# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require "timeout"
require "tmpdir"
require "clacky/default_extensions/codex/runtime"

RSpec.describe Clacky::DefaultExtensions::Codex::Connection do
  class CodexConnectionSpecClient
    Subscription = Struct.new(:method, :handler)

    attr_accessor :agent_capabilities, :auth_methods, :request_handler, :on_start,
      :during_send
    attr_reader :requests, :notifications, :start_arguments

    def initialize
      @agent_capabilities = {}
      @auth_methods = []
      @requests = []
      @notifications = []
      @notification_handlers = Hash.new { |hash, key| hash[key] = [] }
      @request_handlers = {}
      @started = false
    end

    def start(**arguments)
      @start_arguments = arguments
      @started = true
      @on_start&.call(self)
      self
    end

    def initialized?
      @started
    end

    def alive?
      @started
    end

    def request(method, params = {}, timeout: nil, before_send: nil,
                on_sent: nil, on_send_error: nil)
      @requests << [method, params, timeout]
      before_send&.call
      @during_send&.call(method, params)
      on_sent&.call
      @request_handler ? @request_handler.call(method, params, timeout) : {}
    rescue StandardError
      on_send_error&.call
      raise
    end

    def notify(method, params = {})
      @notifications << [method, params]
      nil
    end

    def on_notification(method, session_id: nil, &block)
      subscription = Subscription.new(method, block)
      @notification_handlers[method] << [session_id, subscription]
      subscription
    end

    def remove_notification_handler(subscription)
      @notification_handlers.each_value do |entries|
        return true if entries.delete_if { |_session, item| item == subscription }.any?
      end
      false
    end

    def on_request(method, &block)
      @request_handlers[method] = block
      self
    end

    def emit(method, params)
      @notification_handlers[method].each do |session_id, subscription|
        next if session_id && session_id.to_s != params["sessionId"].to_s

        subscription.handler.call(params)
      end
    end

    def reverse_request(method, params)
      @request_handlers.fetch(method).call(params)
    end

    def stop
      @started = false
    end
  end

  let(:client) { CodexConnectionSpecClient.new }
  let(:home_result) do
    OpenStruct.new(
      managed_home: "/managed/codex",
      auth_reused: true,
      auth_reason: "reused",
      protected_auth_paths: ["/managed/codex/auth.json"],
      protected_paths: ["/private/.clacky"]
    )
  end
  let(:home_manager) { instance_double("CodexHome", prepare: home_result) }
  let(:launcher_result) do
    OpenStruct.new(
      available?: true,
      argv: ["codex-acp"],
      env: { "CODEX_HOME" => "/managed/codex" },
      cwd: "/managed/codex",
      source: :installed,
      version: "1.11.0",
      error_code: nil,
      message: nil
    )
  end
  let(:launcher) { instance_double("Launcher", resolve: launcher_result) }

  def build_connection(client_factory: nil)
    described_class.new(
      home_manager: home_manager,
      launcher_factory: ->(_home_result) { launcher },
      client_factory: client_factory || ->(_launch) { client }
    )
  end

  def eventually(timeout: 2)
    Timeout.timeout(timeout) do
      loop do
        value = yield
        return value if value
        sleep 0.005
      end
    end
  end

  it "reports passive status without preparing or starting the ACP client" do
    connection = build_connection

    expect(connection.passive_status).to include(
      available: nil,
      status: "idle",
      authenticated: nil,
      can_authenticate: true
    )
    expect(client.start_arguments).to be_nil
  ensure
    connection&.close
  end

  it "discovers the authenticated account model catalog in a temporary session" do
    client.request_handler = lambda do |method, _params, _timeout|
      case method
      when "authentication/status"
        { "type" => "account", "label" => "ChatGPT Plus" }
      when "session/new"
        {
          "sessionId" => "discovery-session",
          "configOptions" => [
            {
              "id" => "model",
              "currentValue" => "gpt-5.6-sol",
              "options" => [
                {
                  "name" => "Recommended",
                  "options" => [
                    { "value" => "gpt-6-astra" },
                    { "value" => "gpt-5.6-sol" }
                  ]
                },
                { "value" => "gpt-5.6-sol" }
              ]
            }
          ]
        }
      else
        {}
      end
    end
    connection = build_connection

    expect(connection.discover_models(working_dir: "/workspace")).to include(
      ok: true,
      status: "connected",
      authenticated: true,
      default_model: "gpt-5.6-sol",
      models: ["gpt-6-astra", "gpt-5.6-sol"]
    )
    expect(client.requests).to include(
      [
        "session/new",
        { "cwd" => "/workspace", "mcpServers" => [] },
        nil
      ],
      [
        "session/close",
        { "sessionId" => "discovery-session" },
        described_class::CONTROL_TIMEOUT
      ]
    )
    expect(connection.instance_variable_get(:@sessions)).to be_empty
  ensure
    connection&.close
  end

  it "does not open a discovery session before ChatGPT is authenticated" do
    client.request_handler = lambda do |method, _params, _timeout|
      method == "authentication/status" ? { "type" => "unauthenticated" } : {}
    end
    connection = build_connection

    expect(connection.discover_models).to include(
      ok: false,
      status: "not_connected",
      authenticated: false,
      models: []
    )
    expect(client.requests.map(&:first)).not_to include("session/new")
  ensure
    connection&.close
  end

  it "does not open a discovery session inside a protected credential path" do
    client.request_handler = lambda do |method, _params, _timeout|
      method == "authentication/status" ? { "type" => "account" } : {}
    end
    connection = build_connection

    expect(
      connection.discover_models(working_dir: "/private/.clacky/project")
    ).to include(
      ok: false,
      status: "error",
      authenticated: true,
      models: []
    )
    expect(client.requests.map(&:first)).not_to include("session/new")
  ensure
    connection&.close
  end

  it "closes the temporary session when model discovery cannot parse a catalog" do
    client.request_handler = lambda do |method, _params, _timeout|
      case method
      when "authentication/status"
        { "type" => "account" }
      when "session/new"
        { "sessionId" => "invalid-discovery", "configOptions" => [] }
      else
        {}
      end
    end
    connection = build_connection

    expect(connection.discover_models).to include(
      ok: false,
      status: "error",
      authenticated: true,
      models: []
    )
    expect(client.requests.map(&:first)).to include("session/close")
    expect(connection.instance_variable_get(:@sessions)).to be_empty
  ensure
    connection&.close
  end

  it "always launches the ACP transport from the isolated managed home" do
    connection = build_connection
    acp_client = connection.send(:build_client, launcher_result)
    transport = acp_client.instance_variable_get(:@transport)

    expect(transport.instance_variable_get(:@cwd)).to eq("/managed/codex")
  ensure
    acp_client&.stop
    connection&.close
  end

  it "rejects a workspace inside a protected credential path" do
    connection = build_connection
    connection.status

    expect(connection.workspace_allowed?("/private/.clacky/project")).to be(false)
    expect(connection.workspace_allowed?("/private/.clacky")).to be(false)
    expect(connection.workspace_allowed?("/private")).to be(false)
    expect(connection.workspace_allowed?(File::SEPARATOR)).to be(false)
    expect(connection.workspace_allowed?("/workspace/project")).to be(true)
  ensure
    connection&.close
  end

  it "restarts the exact connection generation after authentication times out" do
    client.auth_methods = [{ "id" => "chat-gpt" }]
    client.request_handler = lambda do |method, _params, _timeout|
      if method == "authentication/status"
        { "type" => "unauthenticated" }
      elsif method == "authenticate"
        raise Clacky::Acp::Client::RequestTimeout, "login timed out"
      else
        {}
      end
    end
    connection = build_connection

    expect(connection.authenticate_async[:started]).to be(true)
    eventually { !client.alive? }
    expect(connection.passive_status).to include(
      status: "idle", authenticated: nil
    )
  ensure
    connection&.close
  end

  it "initializes with only supported client capabilities and caches pushed auth status" do
    client.agent_capabilities = { "_meta" => { "authStatus" => {} } }
    client.auth_methods = [{ "id" => "chat-gpt", "name" => "ChatGPT" }]
    client.on_start = lambda do |started_client|
      started_client.emit(
        "_auth/status_update",
        "authStatus" => { "kind" => "account", "label" => "ChatGPT Plus", "account" => { "email" => "private@example.com" } }
      )
    end

    connection = build_connection
    status = connection.status

    expect(client.start_arguments[:client_info]).to include("name" => "openclacky")
    expect(client.start_arguments[:timeout]).to eq(15)
    expect(client.start_arguments[:capabilities]).to eq(
      "fs" => { "readTextFile" => false, "writeTextFile" => false },
      "terminal" => false,
      "session" => { "configOptions" => { "boolean" => {} } },
      "plan" => {},
      "auth" => { "terminal" => false }
    )
    expect(status).to include(
      available: true,
      status: "connected",
      authenticated: true,
      auth_kind: "account",
      auth_reused: true,
      can_authenticate: true
    )
    expect(connection.health[:message]).to eq("ChatGPT is connected.")
    expect(JSON.generate(status)).not_to include("private@example.com")
  ensure
    connection&.close
  end


  it "allows the pinned npx fallback enough time for its first package resolution" do
    allow(launcher_result).to receive(:source).and_return(:npx)
    client.request_handler = lambda do |method, _params, _timeout|
      method == "authentication/status" ? { "type" => "unauthenticated" } : {}
    end
    connection = build_connection

    connection.status

    expect(client.start_arguments[:timeout]).to eq(300)
  ensure
    connection&.close
  end

  it "uses the deprecated status request only when auth-status push is unavailable" do
    client.agent_capabilities = { "_meta" => {} }
    client.auth_methods = [{ "id" => "chat-gpt" }]
    client.request_handler = lambda do |method, _params, _timeout|
      method == "authentication/status" ? { "type" => "chat-gpt", "email" => "private@example.com" } : {}
    end

    connection = build_connection
    status = connection.status

    expect(status).to include(status: "connected", authenticated: true, auth_kind: "chat-gpt")
    expect(client.requests.map(&:first)).to include("authentication/status")
    expect(JSON.generate(status)).not_to include("private@example.com")
  ensure
    connection&.close
  end

  it "does not treat an advertised auth method as proof of authentication" do
    client.auth_methods = [{ "id" => "chat-gpt" }]
    client.request_handler = lambda do |method, _params, _timeout|
      method == "authentication/status" ? { "type" => "unauthenticated" } : {}
    end

    connection = build_connection

    expect(connection.health).to include(
      status: "not_connected",
      authenticated: false,
      message: "Connect a ChatGPT account to use ChatGPT."
    )
  ensure
    connection&.close
  end

  it "starts browser authentication asynchronously and excludes duplicate login requests" do
    release = Queue.new
    client.agent_capabilities = { "_meta" => { "authStatus" => {} } }
    client.auth_methods = [{ "id" => "chat-gpt" }]
    client.request_handler = lambda do |method, params, _timeout|
      if method == "authenticate"
        expect(params).to eq("methodId" => "chat-gpt")
        release.pop
      end
      {}
    end
    connection = build_connection

    first = connection.authenticate_async
    second = connection.authenticate_async

    expect(first).to include(ok: true, started: true, status: "authenticating")
    expect(second).to include(ok: true, started: false, status: "authenticating")
    eventually { client.requests.count { |request| request.first == "authenticate" } == 1 }
    expect(client.requests.count { |request| request.first == "authenticate" }).to eq(1)
    expect(client.requests.find { |request| request.first == "authenticate" }[2])
      .to eq(described_class::AUTHENTICATION_TIMEOUT)

    client.emit(
      "_auth/status_update",
      "authStatus" => { "kind" => "account", "label" => "ChatGPT" }
    )
    release << true
    eventually { connection.status[:status] == "connected" }
    expect(connection.status).to include(authenticated: true, status: "connected")
  ensure
    release << true if release && release.empty?
    connection&.close
  end

  it "cleans up a failed login so a later attempt can retry" do
    attempts = 0
    client.auth_methods = [{ "id" => "chat-gpt" }]
    client.request_handler = lambda do |method, _params, _timeout|
      if method == "authentication/status"
        { "type" => "unauthenticated" }
      elsif method == "authenticate"
        attempts += 1
        raise Clacky::Acp::Client::ProtocolError, "private remote details"
      else
        {}
      end
    end
    connection = build_connection

    expect(connection.authenticate_async[:started]).to be(true)
    eventually { connection.status[:status] == "error" }
    expect(connection.status[:message]).not_to include("private remote details")
    expect(connection.status[:message]).to eq("ChatGPT authentication did not complete. Try again.")
    eventually { connection.authenticate_async[:started] == true }
    eventually { attempts == 2 }
  ensure
    connection&.close
  end

  it "uses the ChatGPT product name when authentication cannot start" do
    client.auth_methods = [{ "id" => "chat-gpt" }]
    connection = build_connection
    connection.define_singleton_method(:spawn_thread) do |*|
      raise "thread unavailable"
    end

    expect(connection.authenticate_async).to include(
      ok: false,
      started: false,
      status: "error",
      error_code: "authentication_start_failed",
      message: "OpenClacky could not start ChatGPT authentication."
    )
  ensure
    connection&.close
  end

  it "restarts only the client generation that is still current" do
    connection = build_connection
    original_client, original_generation = connection.client_with_generation

    expect(
      connection.restart_if_generation(original_client, original_generation)
    ).to be(true)
    expect(original_client.alive?).to be(false)

    replacement_client, replacement_generation = connection.client_with_generation
    expect(replacement_generation).to be > original_generation
    expect(
      connection.restart_if_generation(original_client, original_generation)
    ).to be(false)
    expect(replacement_client.alive?).to be(true)
  ensure
    connection&.close
  end

  it "does not restart a shared client while another runtime turn is active" do
    connection = build_connection
    original_client, original_generation = connection.client_with_generation
    cancelled_runtime = Object.new
    other_runtime = Object.new
    connection.begin_turn(cancelled_runtime)
    connection.begin_turn(other_runtime)

    expect(
      connection.restart_if_generation(
        original_client,
        original_generation,
        requester: cancelled_runtime
      )
    ).to be(false)
    expect(original_client.alive?).to be(true)

    connection.end_turn(other_runtime)
    expect(
      connection.restart_if_generation(
        original_client,
        original_generation,
        requester: cancelled_runtime
      )
    ).to be(true)
  ensure
    connection&.end_turn(cancelled_runtime) if connection && cancelled_runtime
    connection&.close
  end

  it "does not allow a closed connection to race back to life" do
    connection = build_connection
    connection.client_with_generation

    connection.close

    expect do
      connection.client_with_generation
    end.to raise_error(described_class::UnavailableError) do |error|
      expect(error.code).to eq("connection_closed")
    end
    expect(client.alive?).to be(false)
  ensure
    connection&.close
  end

  it "ignores callbacks from a client generation after it has been restarted" do
    original = CodexConnectionSpecClient.new
    replacement = CodexConnectionSpecClient.new
    [original, replacement].each do |candidate|
      candidate.agent_capabilities = { "_meta" => { "authStatus" => {} } }
      candidate.auth_methods = [{ "id" => "chat-gpt" }]
    end
    clients = [original, replacement]
    connection = build_connection(
      client_factory: ->(_launch) { clients.shift || raise("unexpected client start") }
    )
    old_client, old_generation = connection.client_with_generation
    expect(connection.restart_if_generation(old_client, old_generation)).to be(true)
    connection.client_with_generation

    original.emit(
      "_auth/status_update",
      "authStatus" => { "kind" => "account", "label" => "stale" }
    )

    expect(connection.status[:authenticated]).to be_nil
  ensure
    connection&.close
  end
end

RSpec.describe Clacky::DefaultExtensions::Codex::Runtime do
  class CodexRuntimeSpecConnection
    attr_accessor :on_restart, :workspace_allowed
    attr_reader :client, :bindings, :restart_requests, :active_turns

    def initialize(client)
      @client = client
      @bindings = {}
      @generation = 1
      @restart_requests = []
      @active_turns = []
      @workspace_allowed = true
    end

    def client_with_generation
      [@client, @generation]
    end

    def client_for_generation(generation)
      generation.to_i == @generation ? @client : nil
    end

    def workspace_allowed?(_path)
      @workspace_allowed
    end

    def restart_if_generation(client, generation, requester: nil)
      @restart_requests << [client, generation]
      return false unless client.equal?(@client) && generation.to_i == @generation

      @generation += 1
      @on_restart&.call
      true
    end

    def begin_turn(runtime)
      @active_turns << runtime unless @active_turns.include?(runtime)
    end

    def end_turn(runtime)
      @active_turns.delete(runtime)
    end

    def bind_session(runtime, session_id, previous_session_id: nil)
      existing = @bindings[session_id]
      return false if existing && !existing.equal?(runtime)

      @bindings.delete(previous_session_id) if previous_session_id
      @bindings[session_id] = runtime
      true
    end

    def reserve_session(runtime, session_id)
      bind_session(runtime, session_id)
    end

    def unbind_session(runtime, session_id: nil)
      @bindings.delete_if { |id, value| value.equal?(runtime) && (session_id.nil? || id == session_id) }
    end

    def status
      { available: true, status: "connected", authenticated: true }
    end

    def authenticate_async
      { ok: true, started: true, status: "authenticating" }
    end

    def dispatch_update(params)
      @bindings.fetch(params.fetch("sessionId")).handle_session_update(params)
    end
  end

  let(:client) { CodexConnectionSpecClient.new }
  let(:connection) { CodexRuntimeSpecConnection.new(client) }
  let(:events) { [] }
  let(:ui) do
    Class.new do
      attr_reader :confirmations

      def initialize
        @confirmations = []
      end

      def request_confirmation(message, default: false)
        @confirmations << [message, default]
        false
      end

      def cancel_pending_confirmations(result: false)
        @cancel_result = result
      end
    end.new
  end
  let(:context) do
    {
      session_id: "host-session",
      working_dir: "/workspace",
      permission_mode: "confirm_all",
      ui: ui,
      event_sink: ->(generation, event) { events << [generation, event] }
    }
  end
  let(:config_options) do
    [
      {
        "id" => "mode",
        "category" => "mode",
        "type" => "select",
        "currentValue" => "read-only",
        "options" => [
          { "value" => "read-only", "name" => "Ask for approval" },
          { "value" => "agent", "name" => "Approve for me" },
          { "value" => "agent-full-access", "name" => "Full access" }
        ]
      },
      {
        "id" => "model",
        "category" => "model",
        "type" => "select",
        "currentValue" => "gpt-6-codex",
        "options" => [{ "value" => "gpt-6-codex" }, { "value" => "gpt-5.3-codex" }]
      },
      {
        "id" => "reasoning_effort",
        "category" => "thought_level",
        "type" => "select",
        "currentValue" => "medium",
        "options" => [{ "value" => "medium" }, { "value" => "high" }]
      }
    ]
  end

  def runtime(**options)
    described_class.new(
      context: context,
      persisted_state: nil,
      connection: connection,
      **options
    )
  end

  def input(content = "Hello", files: [], reference_contexts: [])
    Clacky::RuntimeSession::RuntimeInput.new(
      content: content,
      files: files,
      reference_contexts: reference_contexts,
      display_text: content,
      created_at: Time.now.to_f,
      references_display: []
    )
  end

  def install_new_session_handler(prompt_result: { "stopReason" => "end_turn" }, &during_prompt)
    client.agent_capabilities = {
      "promptCapabilities" => { "image" => true },
      "_meta" => { "authStatus" => {} }
    }
    client.request_handler = lambda do |method, params, _timeout|
      case method
      when "session/new"
        { "sessionId" => "acp-session", "configOptions" => config_options }
      when "session/set_config_option"
        { "configOptions" => config_options }
      when "session/prompt"
        during_prompt&.call(params)
        prompt_result
      else
        {}
      end
    end
  end

  def with_pending_prompt(agent)
    started = Queue.new
    release = Queue.new
    install_new_session_handler do
      started << true
      release.pop
    end
    turn = Thread.new { agent.run(input, generation: 999) }
    started.pop

    yield
  ensure
    release << true if release
    turn&.value
  end

  it "creates an ACP session, streams a turn, and completes only on the prompt response" do
    release = Queue.new
    prompt_seen = Queue.new
    install_new_session_handler do |params|
      connection.dispatch_update(
        "sessionId" => "acp-session",
        "update" => {
          "sessionUpdate" => "agent_message_chunk",
          "messageId" => "answer",
          "content" => { "type" => "text", "text" => "Hello from Codex" }
        }
      )
      prompt_seen << params
      release.pop
    end
    agent = runtime

    turn = Thread.new { agent.run(input, generation: 7) }
    params = prompt_seen.pop

    expect(params).to eq(
      "sessionId" => "acp-session",
      "prompt" => [{ "type" => "text", "text" => "Hello" }]
    )
    expect(events).to include([
      7,
      { type: :assistant_delta, message_id: "answer", content: "Hello from Codex" }
    ])
    expect(turn).to be_alive
    release << true
    expect(turn.value).to include(stop_reason: "end_turn")
  ensure
    release << true if release && release.empty?
    agent&.close
  end

  it "does not abandon side-effectful session creation at the short control deadline" do
    install_new_session_handler
    agent = runtime

    expect(agent.run(input, generation: 71)).to include(stop_reason: "end_turn")

    session_open = client.requests.find { |method,| method == "session/new" }
    expect(session_open[2]).to be_nil
  ensure
    agent&.close
  end

  it "exposes ACP model options and switches the open session model" do
    dynamic_options = Marshal.load(Marshal.dump(config_options))
    model_option = dynamic_options.find { |option| option["id"] == "model" }
    model_option["options"] = [
      {
        "name" => "Recommended",
        "options" => [
          { "value" => "gpt-6-codex" },
          { "value" => "gpt-5.6-sol" }
        ]
      },
      { "value" => "gpt-5.6-sol" },
      { "value" => "gpt-5.3-codex" }
    ]
    client.request_handler = lambda do |method, params, _timeout|
      case method
      when "session/new"
        { "sessionId" => "model-session", "configOptions" => dynamic_options }
      when "session/set_config_option"
        updated = Marshal.load(Marshal.dump(dynamic_options))
        updated.find { |option| option["id"] == params["configId"] }["currentValue"] = params["value"]
        dynamic_options = updated
        { "configOptions" => updated }
      when "session/prompt"
        { "stopReason" => "end_turn" }
      else
        {}
      end
    end
    agent = runtime

    expect(agent.capabilities).to include(model_selection: true, sub_model: false)
    expect(agent.model_options).to eq([])
    agent.run(input, generation: 72)

    expect(agent.model_options).to eq(
      ["gpt-6-codex", "gpt-5.6-sol", "gpt-5.3-codex"]
    )
    expect(agent.set_model("gpt-5.6-sol")).to be(true)
    expect(client.requests.select { |request| request.first == "session/set_config_option" }.last).to eq([
      "session/set_config_option",
      {
        "sessionId" => "model-session",
        "configId" => "model",
        "value" => "gpt-5.6-sol"
      },
      described_class::CONTROL_TIMEOUT
    ])
    expect(agent.dump_state).to include("model" => "gpt-5.6-sol")
  ensure
    agent&.close
  end

  it "applies the card default model before the first prompt" do
    install_new_session_handler
    agent = described_class.new(
      context: context.merge(default_model: "gpt-5.3-codex"),
      persisted_state: nil,
      connection: connection
    )

    agent.run(input, generation: 720)

    set_model = client.requests.find do |method, params, _timeout|
      method == "session/set_config_option" && params["configId"] == "model"
    end
    expect(set_model).to eq([
      "session/set_config_option",
      {
        "sessionId" => "acp-session",
        "configId" => "model",
        "value" => "gpt-5.3-codex"
      },
      described_class::CONTROL_TIMEOUT
    ])
    expect(client.requests.map(&:first).index("session/set_config_option"))
      .to be < client.requests.map(&:first).index("session/prompt")
  ensure
    agent&.close
  end

  it "prefers a restored session model over the card default" do
    install_new_session_handler
    agent = described_class.new(
      context: context.merge(default_model: "gpt-6-codex"),
      persisted_state: { "model" => "gpt-5.3-codex" },
      connection: connection
    )

    agent.run(input, generation: 721)

    set_model = client.requests.find do |method, params, _timeout|
      method == "session/set_config_option" && params["configId"] == "model"
    end
    expect(set_model[1]["value"]).to eq("gpt-5.3-codex")
  ensure
    agent&.close
  end

  it "rejects unknown model choices without sending them to ACP" do
    install_new_session_handler
    agent = runtime
    agent.run(input, generation: 73)
    requests_before = client.requests.length

    expect { agent.set_model("not-advertised") }
      .to raise_error(
        described_class::Error,
        "ChatGPT model was not advertised for this session"
      )
    expect(client.requests.length).to eq(requests_before)
  ensure
    agent&.close
  end

  it "uses ChatGPT in model-selection validation messages" do
    agent = runtime

    expect { agent.set_model("") }
      .to raise_error(described_class::Error, "ChatGPT model selection requires a model")
    expect { agent.set_model("gpt-5.6-sol") }
      .to raise_error(
        described_class::Error,
        "ChatGPT model selection is unavailable until the session starts"
      )

    agent.close
    expect { agent.set_model("gpt-5.6-sol") }
      .to raise_error(described_class::Error, "ChatGPT runtime is closed")
  ensure
    agent&.close
  end

  it "rejects model changes while a prompt is in flight" do
    agent = runtime

    with_pending_prompt(agent) do
      expect { agent.set_model("gpt-5.3-codex") }
        .to raise_error(
          Clacky::RuntimeSession::BusyError,
          "ChatGPT model cannot change during an in-flight prompt"
        )
    end
  ensure
    agent&.close
  end

  it "does not open an ACP session for a protected workspace" do
    connection.workspace_allowed = false
    agent = runtime

    expect { agent.run(input, generation: 1) }
      .to raise_error(
        described_class::Error,
        "ChatGPT workspace overlaps a protected credential path"
      )
    expect(client.requests.map(&:first)).not_to include("session/new", "session/resume")
  ensure
    agent&.close
  end

  it "resumes without replaying local history and reapplies only advertised saved model values" do
    client.agent_capabilities = { "promptCapabilities" => { "image" => true } }
    client.request_handler = lambda do |method, params, _timeout|
      case method
      when "session/resume"
        expect(params).to eq(
          "sessionId" => "old-acp-session",
          "cwd" => "/workspace",
          "mcpServers" => []
        )
        { "configOptions" => config_options }
      when "session/set_config_option"
        updated = Marshal.load(Marshal.dump(config_options))
        updated.find { |option| option["id"] == params["configId"] }["currentValue"] = params["value"]
        { "configOptions" => updated }
      when "session/prompt"
        { "stopReason" => "end_turn" }
      else
        {}
      end
    end
    agent = described_class.new(
      context: context,
      persisted_state: {
        "session_id" => "old-acp-session",
        "model" => "gpt-5.3-codex",
        "reasoning_effort" => "high"
      },
      connection: connection
    )

    agent.run(input("Next message"), generation: 8)

    methods = client.requests.map(&:first)
    expect(methods).to include("session/resume", "session/prompt")
    expect(methods).not_to include("session/load")
    expect(client.requests.find { |request| request.first == "session/resume" }[2]).to be_nil
    expect(client.requests.select { |request| request.first == "session/set_config_option" }.map { |request| request[1] }).to include(
      { "sessionId" => "old-acp-session", "configId" => "model", "value" => "gpt-5.3-codex" },
      { "sessionId" => "old-acp-session", "configId" => "reasoning_effort", "value" => "high" }
    )
    expect(client.requests.find { |request| request.first == "session/prompt" }[1]["prompt"]).to eq(
      [{ "type" => "text", "text" => "Next message" }]
    )
  ensure
    agent&.close
  end


  it "preserves saved model choices before the first resumed prompt" do
    agent = described_class.new(
      context: context,
      persisted_state: {
        "session_id" => "old-acp-session",
        "model" => "gpt-5.3-codex",
        "reasoning_effort" => "high"
      },
      connection: connection
    )

    expect(agent.dump_state).to eq(
      "session_id" => "old-acp-session",
      "model" => "gpt-5.3-codex",
      "reasoning_effort" => "high"
    )
  ensure
    agent&.close
  end

  it "does not start ACP merely to close a restored session that was never bound" do
    dormant_connection = Class.new do
      attr_reader :unbound

      def client_with_generation
        raise "closing a dormant session must not start ACP"
      end

      def unbind_session(runtime, session_id: nil)
        @unbound = [runtime, session_id]
      end
    end.new
    agent = described_class.new(
      context: context,
      persisted_state: { "session_id" => "dormant-session" },
      connection: dormant_connection
    )

    expect { agent.close }.not_to raise_error
    expect(dormant_connection.unbound).to eq([agent, "dormant-session"])
  end

  it "does not let duplicate restored session ids steal event routing" do
    client.request_handler = lambda do |method, params, _timeout|
      case method
      when "session/resume"
        { "configOptions" => config_options }
      when "session/new"
        { "sessionId" => "fresh-session", "configOptions" => config_options }
      when "session/prompt"
        { "stopReason" => "end_turn" }
      else
        {}
      end
    end
    first = described_class.new(
      context: context,
      persisted_state: { "session_id" => "shared-session" },
      connection: connection
    )
    second = described_class.new(
      context: context.merge(session_id: "second-host-session"),
      persisted_state: { "session_id" => "shared-session" },
      connection: connection
    )

    first.run(input("first"), generation: 18)
    second.run(input("second"), generation: 19)

    expect(connection.bindings).to include(
      "shared-session" => first,
      "fresh-session" => second
    )
    expect(client.requests.count { |method,| method == "session/resume" }).to eq(1)
    expect(events).to include([
      19,
      hash_including(
        type: :warning,
        code: "resume_conflict",
        content: include("started a new ChatGPT thread")
      )
    ])
  ensure
    first&.close
    second&.close
  end

  it "does not retain a duplicate session id returned by session/new" do
    opened_ids = ["shared-new-session", "shared-new-session", "unique-new-session"]
    client.request_handler = lambda do |method, _params, _timeout|
      case method
      when "session/new"
        { "sessionId" => opened_ids.shift, "configOptions" => config_options }
      when "session/prompt"
        { "stopReason" => "end_turn" }
      else
        {}
      end
    end
    first = runtime
    second = described_class.new(
      context: context.merge(session_id: "second-host-session"),
      connection: connection
    )

    first.run(input("first"), generation: 180)
    expect do
      second.run(input("conflicting"), generation: 181)
    end.to raise_error(described_class::Error, /already owned/)

    expect(second.dump_state["session_id"]).to be_nil
    expect(connection.bindings["shared-new-session"]).to equal(first)

    second.run(input("retry"), generation: 182)
    expect(second.dump_state["session_id"]).to eq("unique-new-session")
    expect(connection.bindings).to include(
      "shared-new-session" => first,
      "unique-new-session" => second
    )
  ensure
    first&.close
    second&.close
  end

  it "falls back to a new ACP session with an explicit warning when resume is missing" do
    client.request_handler = lambda do |method, _params, _timeout|
      case method
      when "session/resume"
        raise Clacky::Acp::Client::ProtocolError.new(
          "unknown session", code: -32_002, method: "session/resume"
        )
      when "session/new"
        { "sessionId" => "replacement", "configOptions" => config_options }
      when "session/prompt"
        { "stopReason" => "end_turn" }
      else
        {}
      end
    end
    agent = described_class.new(
      context: context,
      persisted_state: { "session_id" => "missing" },
      connection: connection
    )

    agent.run(input, generation: 9)

    expect(agent.dump_state["session_id"]).to eq("replacement")
    expect(events).to include([
      9,
      hash_including(
        type: :warning,
        code: "resume_failed",
        content: include("started a new ChatGPT thread")
      )
    ])
  ensure
    agent&.close
  end

  it "falls back when the pinned adapter wraps a missing Codex rollout as an internal error" do
    client.request_handler = lambda do |method, _params, _timeout|
      case method
      when "session/resume"
        raise Clacky::Acp::Client::ProtocolError.new(
          "ACP request 'session/resume' failed (code -32603)",
          code: -32_603,
          method: "session/resume",
          remote_message: "Internal error",
          data: {
            "details" => "no rollout found for thread id missing-rollout"
          }
        )
      when "session/new"
        { "sessionId" => "replacement", "configOptions" => config_options }
      when "session/prompt"
        { "stopReason" => "end_turn" }
      else
        {}
      end
    end
    agent = described_class.new(
      context: context,
      persisted_state: { "session_id" => "missing-rollout" },
      connection: connection
    )

    agent.run(input, generation: 91)

    expect(agent.dump_state["session_id"]).to eq("replacement")
    expect(events).to include([
      91,
      hash_including(
        type: :warning,
        code: "resume_failed",
        content: include("started a new ChatGPT thread")
      )
    ])
  ensure
    agent&.close
  end

  it "does not swallow unrelated adapter internal errors while resuming" do
    client.request_handler = lambda do |method, _params, _timeout|
      if method == "session/resume"
        raise Clacky::Acp::Client::ProtocolError.new(
          "ACP request 'session/resume' failed (code -32603)",
          code: -32_603,
          method: "session/resume",
          remote_message: "Internal error",
          data: { "details" => "database unavailable" }
        )
      end

      raise "unexpected ACP request: #{method}"
    end
    agent = described_class.new(
      context: context,
      persisted_state: { "session_id" => "existing-rollout" },
      connection: connection
    )

    expect { agent.run(input, generation: 92) }
      .to raise_error(Clacky::Acp::Client::ProtocolError)
    expect(client.requests.map(&:first)).to eq(["session/resume"])
  ensure
    agent&.close
  end

  it "does not treat another thread id's missing-rollout error as the restored session" do
    client.request_handler = lambda do |method, _params, _timeout|
      if method == "session/resume"
        raise Clacky::Acp::Client::ProtocolError.new(
          "ACP request 'session/resume' failed (code -32603)",
          code: -32_603,
          method: "session/resume",
          remote_message: "Internal error",
          data: {
            "details" => "no rollout found for thread id different-rollout"
          }
        )
      end

      raise "unexpected ACP request: #{method}"
    end
    agent = described_class.new(
      context: context,
      persisted_state: { "session_id" => "expected-rollout" },
      connection: connection
    )

    expect { agent.run(input, generation: 93) }
      .to raise_error(Clacky::Acp::Client::ProtocolError)
    expect(client.requests.map(&:first)).to eq(["session/resume"])
  ensure
    agent&.close
  end

  it "maps host auto approval only to the advertised agent mode and never full access" do
    auto_context = context.merge(permission_mode: "auto_approve")
    install_new_session_handler
    agent = described_class.new(context: auto_context, connection: connection)

    agent.run(input, generation: 10)

    mode_request = client.requests.find do |method, params, _timeout|
      method == "session/set_config_option" && params["configId"] == "mode"
    end
    expect(mode_request[1]).to eq(
      "sessionId" => "acp-session", "configId" => "mode", "value" => "agent"
    )
    expect(client.requests.map { |request| request[1]["value"] }).not_to include("agent-full-access")
  ensure
    agent&.close
  end

  it "replaces complete config options from updates and persists only effective model and effort" do
    install_new_session_handler
    agent = runtime
    agent.run(input, generation: 11)
    replacement = [
      { "id" => "model", "currentValue" => "gpt-5.3-codex", "options" => [] },
      { "id" => "reasoning_effort", "currentValue" => "high", "options" => [] }
    ]

    connection.dispatch_update(
      "sessionId" => "acp-session",
      "update" => { "sessionUpdate" => "config_option_update", "configOptions" => replacement }
    )

    expect(agent.dump_state).to eq(
      "session_id" => "acp-session",
      "model" => "gpt-5.3-codex",
      "reasoning_effort" => "high"
    )
    expect(JSON.generate(agent.dump_state)).not_to match(/auth|token|api_key/i)
  ensure
    agent&.close
  end

  it "sends advertised image blocks and rejects images when the adapter lacks support" do
    install_new_session_handler
    agent = runtime
    image = { "data_url" => "data:image/png;base64,QUJD", "name" => "image.png" }

    agent.run(input("Inspect", files: [image]), generation: 12)

    prompt = client.requests.find { |request| request.first == "session/prompt" }[1]["prompt"]
    expect(prompt).to eq([
      { "type" => "text", "text" => "Inspect" },
      { "type" => "image", "mimeType" => "image/png", "data" => "QUJD" }
    ])
    agent.close

    unsupported_client = CodexConnectionSpecClient.new
    unsupported_connection = CodexRuntimeSpecConnection.new(unsupported_client)
    unsupported_client.agent_capabilities = { "promptCapabilities" => { "image" => false } }
    unsupported_client.request_handler = lambda do |method, _params, _timeout|
      method == "session/new" ? { "sessionId" => "no-images", "configOptions" => config_options } : {}
    end
    unsupported = described_class.new(context: context, connection: unsupported_connection)
    expect do
      unsupported.run(input("Inspect", files: [image]), generation: 13)
    end.to raise_error(described_class::UnsupportedInput, /image/i)
  ensure
    agent&.close
    unsupported&.close
  end

  it "sends ordinary files and directories as ACP resource links" do
    install_new_session_handler
    agent = runtime

    Dir.mktmpdir("codex-resource-links") do |dir|
      file_path = File.join(dir, "notes with spaces.txt")
      directory_path = File.join(dir, "sources")
      File.write(file_path, "hello")
      Dir.mkdir(directory_path)

      agent.run(
        input(
          "Inspect",
          files: [
            { "name" => "notes.txt", "path" => file_path, "mime_type" => "text/plain" },
            { "name" => "sources", "path" => directory_path, "type" => "directory" }
          ]
        ),
        generation: 13
      )

      prompt = client.requests.find { |request| request.first == "session/prompt" }[1]["prompt"]
      expect(prompt).to include(
        {
          "type" => "resource_link",
          "name" => "notes.txt",
          "uri" => "file://#{file_path.gsub(" ", "%20")}",
          "mimeType" => "text/plain",
          "size" => 5
        },
        {
          "type" => "resource_link",
          "name" => "sources",
          "uri" => "file://#{directory_path}"
        }
      )
    end
  ensure
    agent&.close
  end

  it "emits top-level prompt usage before completing the turn" do
    install_new_session_handler(
      prompt_result: {
        "stopReason" => "end_turn",
        "usage" => {
          "inputTokens" => 12,
          "outputTokens" => 3,
          "cachedReadTokens" => 4,
          "cachedWriteTokens" => 2,
          "totalTokens" => 21
        }
      }
    )
    agent = runtime

    agent.run(input, generation: 14)

    expect(events).to include([
      14,
      {
        type: :usage,
        prompt_tokens: 12,
        completion_tokens: 3,
        cache_read: 4,
        cache_write: 2,
        total_tokens: 21,
        delta_tokens: 21
      }
    ])
  ensure
    agent&.close
  end

  it "enforces one in-flight prompt and sends cooperative cancellation without completing early" do
    stub_const("#{described_class}::CANCEL_GRACE", 0.03)
    release = Queue.new
    started = Queue.new
    install_new_session_handler do |_params|
      started << true
      release.pop
    end
    agent = runtime
    turn = Thread.new { agent.run(input, generation: 14) }
    started.pop

    expect { agent.run(input("second"), generation: 15) }
      .to raise_error(
        described_class::BusyError,
        "ChatGPT session already has an in-flight prompt"
      )
    expect do
      Timeout.timeout(0.05) { agent.run(input("third"), generation: 16) }
    end.to raise_error(described_class::BusyError)
    expect(agent.cancel(reason: :replacement)).to be(true)
    expect(client.notifications).to include([
      "session/cancel", { "sessionId" => "acp-session" }
    ])
    expect(turn).to be_alive
    release << true
    turn.value
    sleep 0.04
    expect(connection.restart_requests).to be_empty
    expect(agent.dump_state["session_id"]).to eq("acp-session")
    expect(connection.bindings).to include("acp-session" => agent)

    release << true
    agent.run(input("after cancellation"), generation: 17)
    expect(client.requests.count { |method,| method == "session/new" }).to eq(1)
  ensure
    release << true if release && release.empty?
    agent&.close
  end

  it "restarts the matching ACP generation only when a cancelled prompt stays pending" do
    stub_const("#{described_class}::CANCEL_GRACE", 0.03)
    release = Queue.new
    started = Queue.new
    install_new_session_handler do |_params|
      started << true
      outcome = release.pop
      raise outcome if outcome.is_a?(Exception)
    end
    connection.on_restart = lambda do
      release << Clacky::Acp::Client::TransportError.new("generation restarted")
    end
    agent = runtime
    turn = Thread.new { agent.run(input, generation: 140) }
    started.pop

    expect(agent.cancel(reason: :replacement)).to be(true)
    Timeout.timeout(1) do
      sleep 0.005 until connection.restart_requests.any?
    end

    expect(connection.restart_requests).to eq([[client, 1]])
    expect(turn.value).to include(stop_reason: "cancelled")
  ensure
    release << true if release && release.empty?
    agent&.close
  end

  it "does not restart ACP merely because an uncancelled prompt is long-running" do
    stub_const("#{described_class}::CANCEL_GRACE", 0.01)
    release = Queue.new
    started = Queue.new
    install_new_session_handler do |_params|
      started << true
      release.pop
    end
    agent = runtime
    turn = Thread.new { agent.run(input, generation: 141) }
    started.pop

    sleep 0.03
    expect(connection.restart_requests).to be_empty

    release << true
    expect(turn.value).to include(stop_reason: "end_turn")
  ensure
    release << true if release && release.empty?
    agent&.close
  end

  it "rejects a permission request that arrives after turn cancellation" do
    release = Queue.new
    started = Queue.new
    install_new_session_handler do |_params|
      started << true
      release.pop
    end
    agent = runtime
    turn = Thread.new { agent.run(input, generation: 142) }
    started.pop
    expect(agent.cancel(reason: :replacement)).to be(true)

    response = agent.handle_permission_request(
      "sessionId" => "acp-session",
      "toolCall" => { "title" => "Late write" },
      "options" => [
        { "optionId" => "allow", "kind" => "allow_once" },
        { "optionId" => "reject", "kind" => "reject_once" }
      ]
    )

    expect(response).to eq("outcome" => { "outcome" => "cancelled" })
    expect(ui.confirmations).to be_empty
    release << true
    turn.value

    response = agent.handle_permission_request(
      "sessionId" => "acp-session",
      "toolCall" => { "title" => "Even later write" },
      "options" => [
        { "optionId" => "allow", "kind" => "allow_once" },
        { "optionId" => "reject", "kind" => "reject_once" }
      ]
    )
    expect(response).to eq("outcome" => { "outcome" => "cancelled" })
    expect(ui.confirmations).to be_empty
  ensure
    release << true if release && release.empty?
    agent&.close
  end

  it "retries mandatory session configuration before reusing an opened session" do
    attempts = 0
    configured_options = Marshal.load(Marshal.dump(config_options))
    configured_options.find { |option| option["id"] == "mode" }["currentValue"] = "agent"
    client.request_handler = lambda do |method, _params, _timeout|
      case method
      when "session/new"
        { "sessionId" => "config-retry", "configOptions" => config_options }
      when "session/set_config_option"
        attempts += 1
        raise Clacky::Acp::Client::RequestTimeout, "first configuration stalled" if attempts == 1

        { "configOptions" => configured_options }
      when "session/prompt"
        { "stopReason" => "end_turn" }
      else
        {}
      end
    end
    agent = described_class.new(
      context: context.merge(permission_mode: "auto_approve"),
      connection: connection
    )

    expect do
      agent.run(input, generation: 143)
    end.to raise_error(Clacky::Acp::Client::RequestTimeout)
    expect(agent.run(input, generation: 144)).to include(stop_reason: "end_turn")

    expect(attempts).to eq(2)
    expect(client.requests.count { |method,| method == "session/new" }).to eq(1)
    expect(client.requests.count { |method,| method == "session/resume" }).to eq(0)
  ensure
    agent&.close
  end

  it "cancels a turn before session creation finishes without sending its prompt" do
    session_started = Queue.new
    session_release = Queue.new
    client.request_handler = lambda do |method, _params, _timeout|
      case method
      when "session/new"
        session_started << true
        session_release.pop
        { "sessionId" => "late-session", "configOptions" => config_options }
      when "session/prompt"
        raise "cancelled prompt must not be sent"
      else
        {}
      end
    end
    agent = runtime
    turn = Thread.new { agent.run(input, generation: 15) }
    session_started.pop

    expect(agent.cancel(reason: :replacement)).to be(true)
    session_release << true

    expect(turn.value).to include(stop_reason: "cancelled")
    expect(client.requests.map(&:first)).not_to include("session/prompt")
    expect(connection.bindings).to be_empty
    expect(client.requests).to include(
      ["session/close", { "sessionId" => "late-session" }, 5]
    )
  ensure
    session_release << true if session_release && session_release.empty?
    agent&.close
  end

  it "closes a runtime while session creation is pending without binding the late session" do
    session_started = Queue.new
    session_release = Queue.new
    client.request_handler = lambda do |method, _params, _timeout|
      case method
      when "session/new"
        session_started << true
        session_release.pop
        { "sessionId" => "orphan-session", "configOptions" => config_options }
      when "session/close"
        {}
      when "session/prompt"
        raise "closed runtime must not send a prompt"
      else
        {}
      end
    end
    agent = runtime
    turn = Thread.new { agent.run(input, generation: 15) }
    session_started.pop

    agent.close
    session_release << true

    expect(turn.value).to include(stop_reason: "cancelled")
    expect(connection.bindings).to be_empty
    expect(client.requests).to include([
      "session/close", { "sessionId" => "orphan-session" }, 5
    ])
    expect(client.requests.map(&:first)).not_to include("session/prompt")
  ensure
    session_release << true if session_release && session_release.empty?
    agent&.close
  end

  it "normalizes thought, tool, plan, usage, session-info, and unknown updates with the active generation" do
    install_new_session_handler
    agent = runtime
    agent.run(input, generation: 16)
    updates = [
      { "sessionUpdate" => "agent_thought_chunk", "content" => { "type" => "text", "text" => "thinking" } },
      { "sessionUpdate" => "tool_call", "toolCallId" => "tool-1", "title" => "Run tests", "kind" => "execute", "rawInput" => { "command" => "rspec" } },
      { "sessionUpdate" => "tool_call_update", "toolCallId" => "tool-1", "status" => "completed", "rawOutput" => "ok" },
      { "sessionUpdate" => "plan", "entries" => [{ "content" => "Test", "priority" => "high", "status" => "pending" }] },
      { "sessionUpdate" => "plan_update", "plan" => { "type" => "markdown", "planId" => "plan-1", "content" => "1. Run tests" } },
      { "sessionUpdate" => "usage_update", "used" => 10, "size" => 100 },
      { "sessionUpdate" => "session_info_update", "title" => "Codex task" },
      {
        "sessionUpdate" => "session_info_update",
        "_meta" => {
          "codex" => {
            "error" => {
              "message" => "temporary upstream failure",
              "willRetry" => true
            }
          }
        }
      },
      { "sessionUpdate" => "future_update", "value" => 1 }
    ]
    agent.instance_variable_set(:@active_generation, 16)

    updates.each do |update|
      agent.handle_session_update("sessionId" => "acp-session", "update" => update)
    end

    normalized = events.select { |generation, _event| generation == 16 }.map(&:last)
    expect(normalized).to include(
      hash_including(type: :thought, content: "thinking"),
      hash_including(type: :tool_call, tool_call_id: "tool-1", name: "Run tests"),
      hash_including(type: :tool_result, tool_call_id: "tool-1", result: "ok"),
      hash_including(type: :plan),
      hash_including(type: :plan, plan_id: "plan-1", content: "1. Run tests"),
      hash_including(type: :usage, used: 10, size: 100),
      hash_including(type: :session_info, title: "Codex task"),
      hash_including(
        type: :warning,
        code: "codex_retry",
        content: include("ChatGPT", "retrying")
      ),
      hash_including(type: :unknown, session_update: "future_update")
    )
  ensure
    agent&.close
  end

  it "maps ACP plan content to the host todo task field" do
    install_new_session_handler
    agent = runtime
    agent.run(input, generation: 17)
    agent.instance_variable_set(:@active_generation, 17)

    agent.handle_session_update(
      "sessionId" => "acp-session",
      "update" => {
        "sessionUpdate" => "plan",
        "entries" => [
          { "content" => "Run tests", "priority" => "high", "status" => "pending" }
        ]
      }
    )

    expect(events.last).to eq([
      17,
      {
        type: :plan,
        entries: [{ "task" => "Run tests", "priority" => "high", "status" => "pending" }]
      }
    ])
  ensure
    agent&.close
  end

  it "emits and clears a tool result when terminal status arrives on tool_call" do
    install_new_session_handler
    agent = runtime
    agent.run(input, generation: 18)
    agent.instance_variable_set(:@active_generation, 18)

    agent.handle_session_update(
      "sessionId" => "acp-session",
      "update" => {
        "sessionUpdate" => "tool_call",
        "toolCallId" => "tool-complete",
        "title" => "Read file",
        "status" => "completed",
        "rawInput" => { "path" => "README.md" },
        "rawOutput" => "contents"
      }
    )

    expect(events[-2]).to match([
      18, hash_including(type: :tool_call, tool_call_id: "tool-complete")
    ])
    expect(events[-1]).to match([
      18,
      hash_including(
        type: :tool_result,
        tool_call_id: "tool-complete",
        result: "contents"
      )
    ])
    expect(agent.instance_variable_get(:@tools)).not_to have_key("tool-complete")
  ensure
    agent&.close
  end

  it "normalizes codex-acp command output and preserves failed exit metadata" do
    install_new_session_handler
    agent = runtime
    agent.run(input, generation: 181)
    agent.instance_variable_set(:@active_generation, 181)

    agent.handle_session_update(
      "sessionId" => "acp-session",
      "update" => {
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "tool-failed",
        "title" => "Run tests",
        "status" => "failed",
        "rawOutput" => {
          "formatted_output" => "2 examples, 1 failure",
          "exit_code" => 1
        }
      }
    )

    expect(events.last).to eq([
      181,
      {
        type: :tool_result,
        tool_call_id: "tool-failed",
        result: "2 examples, 1 failure",
        status: "failed",
        exit_code: 1
      }
    ])
  ensure
    agent&.close
  end

  it "defaults permission requests to the advertised one-shot reject option" do
    agent = runtime
    response = with_pending_prompt(agent) do
      agent.handle_permission_request(
        "sessionId" => "acp-session",
        "toolCall" => { "title" => "Edit files" },
        "options" => [
          { "optionId" => "allow", "kind" => "allow_once" },
          { "optionId" => "reject", "kind" => "reject_once" }
        ]
      )
    end

    expect(response).to eq(
      "outcome" => { "outcome" => "selected", "optionId" => "reject" }
    )
    expect(ui.confirmations).to eq([["Edit files", false]])
  ensure
    agent&.close
  end

  it "uses ChatGPT in the fallback permission title" do
    agent = runtime

    with_pending_prompt(agent) do
      agent.handle_permission_request(
        "sessionId" => "acp-session",
        "toolCall" => {},
        "options" => [
          { "optionId" => "allow", "kind" => "allow_once" },
          { "optionId" => "reject", "kind" => "reject_once" }
        ]
      )
    end

    expect(ui.confirmations.last.first).to eq("Allow this ChatGPT action?")
  ensure
    agent&.close
  end

  it "accepts a permission request that arrives as the prompt write becomes visible" do
    response = nil
    agent = runtime
    install_new_session_handler
    client.during_send = lambda do |method, _params|
      next unless method == "session/prompt"

      response = agent.handle_permission_request(
        "sessionId" => "acp-session",
        "toolCall" => { "title" => "Fast permission" },
        "options" => [
          { "optionId" => "allow", "kind" => "allow_once" },
          { "optionId" => "reject", "kind" => "reject_once" }
        ]
      )
    end

    agent.run(input, generation: 182)

    expect(response).to eq(
      "outcome" => { "outcome" => "selected", "optionId" => "reject" }
    )
    expect(ui.confirmations).to include(["Fast permission", false])
  ensure
    agent&.close
  end

  it "shows the concrete command and working directory in permission prompts" do
    agent = runtime

    with_pending_prompt(agent) do
      agent.handle_permission_request(
        "sessionId" => "acp-session",
        "toolCall" => {
          "title" => "Run command",
          "rawInput" => { "command" => "bundle exec rspec", "cwd" => "/workspace" }
        },
        "options" => [
          { "optionId" => "allow", "kind" => "allow_once" },
          { "optionId" => "reject", "kind" => "reject_once" }
        ]
      )
    end

    expect(ui.confirmations.last.first).to include(
      "Run command", "bundle exec rspec", "/workspace"
    )
  ensure
    agent&.close
  end

  it "auto-approves only the advertised one-shot option in host auto mode" do
    raising_ui = Class.new do
      def request_confirmation(*)
        raise "auto approval must not wait for the browser"
      end
    end.new
    agent = described_class.new(
      context: context.merge(permission_mode: "auto_approve", ui: raising_ui),
      connection: connection
    )

    response = with_pending_prompt(agent) do
      agent.handle_permission_request(
        "sessionId" => "acp-session",
        "toolCall" => { "title" => "Run command" },
        "options" => [
          { "optionId" => "once", "kind" => "allow_once" },
          { "optionId" => "always", "kind" => "allow_always" }
        ]
      )
    end

    expect(response).to eq(
      "outcome" => { "outcome" => "selected", "optionId" => "once" }
    )
  ensure
    agent&.close
  end

  it "never promotes an ordinary approval into a persistent allow option" do
    approving_ui = Class.new do
      def request_confirmation(_message, default: false)
        true
      end
    end.new
    agent = described_class.new(
      context: context.merge(ui: approving_ui),
      connection: connection
    )

    response = with_pending_prompt(agent) do
      agent.handle_permission_request(
        "sessionId" => "acp-session",
        "toolCall" => { "title" => "Edit files" },
        "options" => [
          { "optionId" => "always", "kind" => "allow_always" },
          { "optionId" => "reject", "kind" => "reject_once" }
        ]
      )
    end

    expect(response).to eq("outcome" => { "outcome" => "cancelled" })
  ensure
    agent&.close
  end

  it "maps a cancelled host confirmation to ACP cancellation" do
    cancelled_ui = Class.new do
      def request_confirmation(_message, default: false)
        "cancelled"
      end
    end.new
    agent = described_class.new(
      context: context.merge(ui: cancelled_ui),
      connection: connection
    )

    response = with_pending_prompt(agent) do
      agent.handle_permission_request(
        "sessionId" => "acp-session",
        "toolCall" => { "title" => "Edit files" },
        "options" => [
          { "optionId" => "allow", "kind" => "allow_once" },
          { "optionId" => "reject", "kind" => "reject_once" }
        ]
      )
    end

    expect(response).to eq("outcome" => { "outcome" => "cancelled" })
  ensure
    agent&.close
  end
end
