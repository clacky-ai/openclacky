# frozen_string_literal: true

require "json"
require "uri"
require_relative "../../thread_registry"
require_relative "../../runtime_session"
require_relative "codex_home"
require_relative "launcher"

module Clacky
  module DefaultExtensions
    module Codex
      # Owns the shared codex-acp connection, authentication state, and routing
      # for session-scoped notifications and permission requests.
      class Connection
        class UnavailableError < StandardError
          attr_reader :code

          def initialize(code, message)
            @code = code.to_s
            super(message.to_s)
          end
        end

        CONTROL_TIMEOUT = 5
        INITIALIZE_TIMEOUT = 15
        # The first npx launch may need to fetch the platform-specific Codex
        # package (currently over 100 MB) before ACP initialization can begin.
        NPX_INITIALIZE_TIMEOUT = 300
        AUTHENTICATION_TIMEOUT = 300
        AUTH_STATUS_WAIT = 0.25
        MAX_MESSAGE_BYTES = 8 * 1024 * 1024
        STDERR_BYTES = 16 * 1024

        def initialize(home_manager: nil, launcher_factory: nil,
                       client_factory: nil, thread_spawner: nil)
          @home_manager = home_manager || CodexHome.new
          @launcher_factory = launcher_factory || method(:build_launcher)
          @client_factory = client_factory || method(:build_client)
          @thread_spawner = thread_spawner

          @lifecycle_mutex = Mutex.new
          @callback_mutex = Mutex.new
          @state_mutex = Mutex.new
          @state_condition = ConditionVariable.new
          @auth_mutex = Mutex.new
          @discovery_mutex = Mutex.new
          @sessions_mutex = Mutex.new
          @turns_mutex = Mutex.new
          @sessions = {}
          @active_turns = {}
          @client = nil
          @callback_identity = nil
          @generation = 0
          @closed = false
          @home_result = nil
          @launcher_result = nil
          @auth_state = nil
          @auth_error = nil
          @authenticating = false
          @auth_thread = nil
          @auth_push_supported = false
        end

        def client_with_generation
          @lifecycle_mutex.synchronize do
            [ensure_client_locked, @generation]
          end
        end

        def client_for_generation(generation)
          @lifecycle_mutex.synchronize do
            next nil unless generation && @generation.to_i == generation.to_i
            next nil unless @client && @client.initialized?
            next nil if @client.respond_to?(:alive?) && !@client.alive?

            @client
          end
        end

        def status
          ensure_client
          wait_for_initial_auth_status if @auth_push_supported
          status_snapshot
        rescue UnavailableError => e
          unavailable_status(e.code, e.message)
        rescue StandardError
          unavailable_status(
            "acp_unavailable",
            "OpenClacky could not start the Codex ACP runtime."
          )
        end

        # Readiness view for GET endpoints. It never prepares a home, resolves
        # npx, or starts a process; those side effects require an explicit POST
        # to connect/authenticate or a real runtime health check.
        def passive_status
          client, closed = @lifecycle_mutex.synchronize { [@client, @closed] }
          return unavailable_status("connection_closed", "The Codex ACP connection is closed.") if closed

          if client && client.initialized? &&
             (!client.respond_to?(:alive?) || client.alive?)
            return status_snapshot
          end

          launch = @launcher_result
          if launch && !launch.available?
            return unavailable_status(
              launch.error_code || "launcher_unavailable",
              launch.message || "Codex ACP launch dependencies are unavailable."
            )
          end

          home = @home_result
          {
            available: nil,
            status: "idle",
            authenticated: nil,
            auth_reused: home && home.auth_reused == true,
            auth_reason: home && home.auth_reason,
            can_authenticate: true
          }
        rescue StandardError
          unavailable_status(
            "acp_unavailable",
            "OpenClacky could not inspect the Codex ACP runtime."
          )
        end

        def health
          snapshot = status
          snapshot.merge(
            ok: snapshot[:available] == true && snapshot[:authenticated] == true,
            message: health_message(snapshot)
          )
        end

        def workspace_allowed?(working_dir)
          candidate = canonical_path(working_dir)
          protected_paths = @home_result&.respond_to?(:protected_paths) ?
            Array(@home_result.protected_paths) : []
          protected_paths.none? do |protected_path|
            protected_candidate = canonical_path(protected_path)
            inside_path?(candidate, protected_candidate) ||
              inside_path?(protected_candidate, candidate)
          end
        end

        def authenticate_async
          client, generation = client_with_generation
          unless client.auth_methods.any? { |method| method["id"].to_s == "chat-gpt" }
            return {
              ok: false,
              started: false,
              status: "unavailable",
              error_code: "chatgpt_auth_unavailable",
              message: "The Codex ACP runtime did not advertise ChatGPT browser login."
            }
          end

          @auth_mutex.synchronize do
            if @auth_thread&.alive? && @auth_thread_generation == generation
              return { ok: true, started: false, status: "authenticating" }
            end

            @state_mutex.synchronize do
              @authenticating = true
              @auth_error = nil
              @state_condition.broadcast
            end
            @auth_thread_generation = generation
            @auth_thread = spawn_thread("codex-acp-authenticate") do
              run_authentication(client, generation)
            end
          end
          { ok: true, started: true, status: "authenticating" }
        rescue UnavailableError => e
          {
            ok: false,
            started: false,
            status: "unavailable",
            error_code: e.code,
            message: e.message
          }
        rescue StandardError
          {
            ok: false,
            started: false,
            status: "error",
            error_code: "authentication_start_failed",
            message: "OpenClacky could not start ChatGPT authentication."
          }
        end

        # Open a short-lived, unbound ACP session to read the account-scoped
        # model catalog before OpenClacky creates a user-visible conversation.
        def discover_models(working_dir: Dir.pwd)
          snapshot = nil
          @discovery_mutex.synchronize do
            client = ensure_client
            wait_for_initial_auth_status if @auth_push_supported
            snapshot = status_snapshot
            unless snapshot[:authenticated] == true
              next discovery_result(
                snapshot,
                ok: false,
                models: [],
                message: "Connect a ChatGPT account before choosing a model."
              )
            end
            unless workspace_allowed?(working_dir)
              next discovery_result(
                snapshot,
                ok: false,
                models: [],
                message: "ChatGPT model discovery cannot use a protected credential path."
              ).merge(status: "error")
            end

            session_id = nil
            begin
              response = client.request(
                "session/new",
                {
                  "cwd" => File.expand_path(working_dir.to_s),
                  "mcpServers" => []
                },
                timeout: nil
              )
              session_id = response["sessionId"].to_s.strip
              if session_id.empty?
                raise UnavailableError.new(
                  "model_discovery_failed",
                  "ChatGPT did not return a discovery session."
                )
              end

              model_option = Array(response["configOptions"]).find do |option|
                option.is_a?(Hash) && option["id"].to_s == "model"
              end
              models = discovery_model_values(model_option && model_option["options"])
              if models.empty?
                raise UnavailableError.new(
                  "model_discovery_failed",
                  "ChatGPT did not advertise any available models."
                )
              end
              current = bounded_string(model_option["currentValue"])
              current = models.first unless models.include?(current)
              discovery_result(
                snapshot,
                ok: true,
                default_model: current,
                models: models,
                message: "ChatGPT models are ready."
              )
            rescue UnavailableError => e
              discovery_result(
                snapshot,
                ok: false,
                models: [],
                message: e.message
              ).merge(status: "error")
            rescue StandardError
              discovery_result(
                snapshot,
                ok: false,
                models: [],
                message: "OpenClacky could not load the ChatGPT model list."
              ).merge(status: "error")
            ensure
              if session_id && !session_id.empty?
                begin
                  client.request(
                    "session/close",
                    { "sessionId" => session_id },
                    timeout: CONTROL_TIMEOUT
                  )
                rescue StandardError
                  nil
                end
              end
            end
          end
        rescue UnavailableError => e
          {
            ok: false,
            status: "unavailable",
            authenticated: nil,
            models: [],
            message: e.message
          }
        rescue StandardError
          {
            ok: false,
            status: "unavailable",
            authenticated: nil,
            models: [],
            message: "OpenClacky could not load the ChatGPT model list."
          }
        end

        def bind_session(runtime, session_id, previous_session_id: nil)
          @sessions_mutex.synchronize do
            existing = @sessions[session_id.to_s]
            return false if existing && !existing.equal?(runtime)

            if previous_session_id && previous_session_id.to_s != session_id.to_s
              previous = @sessions[previous_session_id.to_s]
              @sessions.delete(previous_session_id.to_s) if previous.equal?(runtime)
            end
            @sessions[session_id.to_s] = runtime
            true
          end
        end

        def reserve_session(runtime, session_id)
          bind_session(runtime, session_id)
        end

        def unbind_session(runtime, session_id: nil)
          @sessions_mutex.synchronize do
            @sessions.delete_if do |id, value|
              value.equal?(runtime) && (session_id.nil? || id == session_id.to_s)
            end
          end
        end

        def begin_turn(runtime)
          @turns_mutex.synchronize do
            @lifecycle_mutex.synchronize do
              raise UnavailableError.new(
                "connection_closed", "The Codex ACP connection is closed."
              ) if @closed
            end
            @active_turns[runtime.object_id] = runtime
          end
          true
        end

        def end_turn(runtime)
          @turns_mutex.synchronize { @active_turns.delete(runtime.object_id) }
          true
        end

        # Stop a wedged ACP process only if it is still the exact connection
        # generation observed by the cancelled request. A stale watchdog must
        # never tear down a replacement process started by a later turn.
        def restart_if_generation(client, generation, requester: nil)
          @turns_mutex.synchronize do
            other_turn_active = @active_turns.values.any? do |runtime|
              requester.nil? || !runtime.equal?(requester)
            end
            return false if other_turn_active

            @lifecycle_mutex.synchronize do
              return false if @closed
              return false unless @client.equal?(client)
              return false unless @generation.to_i == generation.to_i

              @client = nil
              @auth_push_supported = false
              deactivate_client_callbacks(client)
              client.stop
              reset_connection_auth_state
              true
            end
          end
        rescue StandardError
          false
        end

        def close
          closed_now = @lifecycle_mutex.synchronize do
            return nil if @closed

            @closed = true
            existing = @client
            @client = nil
            deactivate_client_callbacks(existing)
            existing&.stop
            true
          end
          return nil unless closed_now

          thread = @auth_mutex.synchronize { @auth_thread }
          thread&.join(1) unless thread == Thread.current
          @sessions_mutex.synchronize { @sessions.clear }
          @turns_mutex.synchronize { @active_turns.clear }
          @state_mutex.synchronize do
            @authenticating = false
            @auth_state = nil
            @state_condition.broadcast
          end
          nil
        rescue StandardError
          nil
        end

        private def ensure_client
          @lifecycle_mutex.synchronize do
            ensure_client_locked
          end
        end

        private def ensure_client_locked
          if @closed
            raise UnavailableError.new(
              "connection_closed", "The Codex ACP connection is closed."
            )
          end
          if @client && @client.initialized? &&
             (!@client.respond_to?(:alive?) || @client.alive?)
            return @client
          end

          old_client = @client
          @client = nil
          deactivate_client_callbacks(old_client)
          old_client&.stop
          start_client
        end

        private def start_client
          home_result = @home_manager.prepare
          launcher = @launcher_factory.call(home_result)
          launch = launcher.resolve
          @home_result = home_result
          @launcher_result = launch
          unless launch.available?
            raise UnavailableError.new(
              launch.error_code || "launcher_unavailable",
              launch.message || "Codex ACP launch dependencies are unavailable."
            )
          end

          client = @client_factory.call(launch)
          callback_token = activate_client_callbacks(client)
          install_handlers(client, callback_token)
          reset_connection_auth_state
          client.start(
            client_info: {
              "name" => "openclacky",
              "title" => "OpenClacky",
              "version" => Clacky.const_defined?(:VERSION) ? Clacky::VERSION.to_s : "unknown"
            },
            capabilities: client_capabilities,
            timeout: launch.source == :npx ? NPX_INITIALIZE_TIMEOUT : INITIALIZE_TIMEOUT
          )

          capabilities = client.agent_capabilities
          @auth_push_supported = !capabilities.dig("_meta", "authStatus").nil?
          refresh_legacy_auth_status(client) unless @auth_push_supported
          @generation += 1
          @client = client
        rescue StandardError
          deactivate_client_callbacks(client)
          client&.stop rescue nil
          raise
        end

        private def install_handlers(client, callback_token)
          client.on_notification("_auth/status_update") do |params|
            next unless current_client_callback?(client, callback_token)

            apply_auth_status(params["authStatus"])
          end
          client.on_notification("session/update") do |params|
            next unless current_client_callback?(client, callback_token)

            dispatch_session_update(params)
          end
          client.on_request("session/request_permission") do |params|
            if current_client_callback?(client, callback_token)
              dispatch_permission_request(params)
            else
              Runtime.rejected_permission_response(params)
            end
          end
        end

        private def activate_client_callbacks(client)
          token = Object.new
          @callback_mutex.synchronize do
            @callback_identity = [client, token]
          end
          token
        end

        private def deactivate_client_callbacks(client)
          return unless client

          @callback_mutex.synchronize do
            identity = @callback_identity
            @callback_identity = nil if identity && identity[0].equal?(client)
          end
        end

        private def current_client_callback?(client, token)
          @callback_mutex.synchronize do
            identity = @callback_identity
            identity && identity[0].equal?(client) && identity[1].equal?(token)
          end
        end

        private def client_capabilities
          {
            "fs" => { "readTextFile" => false, "writeTextFile" => false },
            "terminal" => false,
            "session" => { "configOptions" => { "boolean" => {} } },
            "plan" => {},
            "auth" => { "terminal" => false }
          }
        end

        private def build_launcher(home_result)
          Launcher.new(
            codex_home: home_result.managed_home,
            explicit_path: ENV["CLACKY_CODEX_ACP_PATH"],
            codex_path: ENV["CLACKY_CODEX_PATH"],
            protected_auth_paths: home_result.respond_to?(:protected_auth_paths) ?
              home_result.protected_auth_paths : [],
            protected_paths: home_result.respond_to?(:protected_paths) ?
              home_result.protected_paths : []
          )
        end

        private def build_client(launch)
          transport = Clacky::Acp::ProcessTransport.new(
            name: "codex-acp",
            argv: launch.argv,
            env: launch.env,
            cwd: launch.cwd,
            max_message_bytes: MAX_MESSAGE_BYTES,
            stderr_bytes: STDERR_BYTES
          )
          Clacky::Acp::Client.new(transport: transport)
        end

        private def reset_connection_auth_state
          @state_mutex.synchronize do
            @auth_state = nil
            @auth_error = nil
            @authenticating = false
          end
        end

        private def refresh_legacy_auth_status(client)
          result = client.request(
            "authentication/status", {}, timeout: CONTROL_TIMEOUT
          )
          apply_auth_status(result)
        rescue Clacky::Acp::Client::Error
          nil
        end

        private def apply_auth_status(raw_status)
          normalized = normalize_auth_status(raw_status)
          return unless normalized

          @state_mutex.synchronize do
            @auth_state = normalized
            @auth_error = nil
            @state_condition.broadcast
          end
        end

        private def normalize_auth_status(raw_status)
          return nil unless raw_status.is_a?(Hash)

          kind = (raw_status["kind"] || raw_status["type"]).to_s
          case kind
          when "none", "unauthenticated"
            { authenticated: false, kind: kind, label: safe_label(raw_status) }
          when "account", "chat-gpt", "api_key", "api-key", "gateway", "external"
            { authenticated: true, kind: kind, label: safe_label(raw_status) }
          else
            nil
          end
        end

        private def safe_label(raw_status)
          label = raw_status["label"].to_s.strip
          return nil if label.empty?

          label.byteslice(0, 120).to_s.force_encoding(Encoding::UTF_8).scrub
        end

        private def discovery_result(snapshot, ok:, models:, message:,
                                     default_model: nil)
          result = {
            ok: ok,
            status: snapshot[:status],
            authenticated: snapshot[:authenticated],
            models: models,
            message: message
          }
          result[:default_model] = default_model if default_model
          result
        end

        private def discovery_model_values(options)
          flatten_discovery_options(options).filter_map do |entry|
            bounded_string(entry["value"])
          end.reject(&:empty?).uniq.first(100)
        end

        private def flatten_discovery_options(options)
          Array(options).each_with_object([]) do |entry, flattened|
            next unless entry.is_a?(Hash)

            if entry["options"].is_a?(Array)
              flattened.concat(flatten_discovery_options(entry["options"]))
            else
              flattened << entry
            end
          end
        end

        private def bounded_string(value)
          value.to_s.byteslice(0, 200).to_s.force_encoding(Encoding::UTF_8).scrub.strip
        end

        private def wait_for_initial_auth_status
          @state_mutex.synchronize do
            if @auth_state.nil? && @auth_error.nil? && !@authenticating
              @state_condition.wait(@state_mutex, AUTH_STATUS_WAIT)
            end
          end
        end

        private def status_snapshot
          state = @state_mutex.synchronize do
            {
              auth_state: @auth_state && @auth_state.dup,
              auth_error: @auth_error,
              authenticating: @authenticating
            }
          end
          launch = @launcher_result
          home = @home_result
          auth_state = state[:auth_state]
          status = if state[:authenticating]
                     "authenticating"
                   elsif state[:auth_error]
                     "error"
                   elsif auth_state && auth_state[:authenticated]
                     "connected"
                   elsif auth_state
                     "not_connected"
                   else
                     "unknown"
                   end
          payload = {
            available: true,
            status: status,
            authenticated: auth_state && auth_state[:authenticated],
            auth_reused: home && home.auth_reused == true,
            auth_reason: home && home.auth_reason,
            can_authenticate: current_client_auth_method?("chat-gpt")
          }
          payload[:auth_kind] = auth_state[:kind] if auth_state
          payload[:label] = auth_state[:label] if auth_state && auth_state[:label]
          payload[:launcher] = launch.source.to_s if launch&.source
          payload[:version] = launch.version if launch&.version
          if state[:auth_error]
            payload[:error_code] = "authentication_failed"
            payload[:message] = "ChatGPT authentication did not complete. Try again."
          end
          payload
        end

        private def current_client_auth_method?(method_id)
          client = @client
          client && client.auth_methods.any? { |method| method["id"].to_s == method_id }
        end

        private def unavailable_status(code, message)
          home = @home_result
          {
            available: false,
            status: "unavailable",
            authenticated: nil,
            auth_reused: home && home.auth_reused == true,
            auth_reason: home && home.auth_reason,
            can_authenticate: false,
            error_code: code.to_s,
            message: message.to_s
          }
        end

        private def health_message(snapshot)
          return snapshot[:message] if snapshot[:message]
          return "ChatGPT is connected." if snapshot[:authenticated] == true
          return "Connect a ChatGPT account to use ChatGPT." if snapshot[:authenticated] == false

          "Waiting for ChatGPT authentication status."
        end

        private def canonical_path(path)
          expanded = File.expand_path(path.to_s)
          File.exist?(expanded) ? File.realpath(expanded) : expanded
        rescue SystemCallError
          expanded || File.expand_path(path.to_s)
        end

        private def inside_path?(candidate, parent)
          candidate == parent ||
            candidate.start_with?(parent.chomp(File::SEPARATOR) + File::SEPARATOR)
        end

        private def run_authentication(client, generation)
          client.request(
            "authenticate", { "methodId" => "chat-gpt" },
            timeout: AUTHENTICATION_TIMEOUT
          )
          if current_client_generation?(client, generation)
            @state_mutex.synchronize do
              @auth_state ||= {
                authenticated: true,
                kind: "account",
                label: "ChatGPT"
              }
              @auth_error = nil
            end
          end
        rescue Clacky::Acp::Client::RequestTimeout
          restarted = restart_if_generation(client, generation)
          unless restarted
            if current_client_generation?(client, generation)
              @state_mutex.synchronize { @auth_error = true }
            end
          end
        rescue StandardError
          if current_client_generation?(client, generation)
            @state_mutex.synchronize { @auth_error = true }
          end
        ensure
          if current_client_generation?(client, generation)
            @state_mutex.synchronize do
              @authenticating = false
              @state_condition.broadcast
            end
          end
          @auth_mutex.synchronize do
            if @auth_thread == Thread.current
              @auth_thread = nil
              @auth_thread_generation = nil
            end
          end
        end

        private def current_client_generation?(client, generation)
          @lifecycle_mutex.synchronize do
            @client.equal?(client) && @generation.to_i == generation.to_i
          end
        end

        private def dispatch_session_update(params)
          runtime = @sessions_mutex.synchronize do
            @sessions[params["sessionId"].to_s]
          end
          runtime&.handle_session_update(params)
        end

        private def dispatch_permission_request(params)
          runtime = @sessions_mutex.synchronize do
            @sessions[params["sessionId"].to_s]
          end
          return runtime.handle_permission_request(params) if runtime

          Runtime.rejected_permission_response(params)
        end

        private def spawn_thread(name, &block)
          return @thread_spawner.call(name, &block) if @thread_spawner

          Clacky::ThreadRegistry.spawn(name: name, daemon: true, &block)
        end
      end

      # Implements one OpenClacky agent-runtime instance over a shared ACP v1
      # connection. The host remains authoritative for transcript and queueing.
      class Runtime
        class Error < StandardError; end
        class BusyError < Error; end
        class UnsupportedInput < Error; end
        class TurnCancelled < Error; end

        CONTROL_TIMEOUT = 5
        CANCEL_GRACE = 1.0
        MAX_THOUGHT_BYTES = 8 * 1024
        MISSING_ROLLOUT_ERROR_PREFIX = "no rollout found for thread id "
        RESUME_CONFLICT_WARNING =
          "ChatGPT could not reuse the saved runtime context because it is " \
          "already active elsewhere. This turn started a new ChatGPT thread; " \
          "the transcript remains visible, but the new thread received only " \
          "this turn."
        RESUME_FAILED_WARNING =
          "ChatGPT could not resume the saved runtime context. This turn " \
          "started a new ChatGPT thread; the transcript remains visible, but " \
          "the new thread received only this turn."
        CODEX_RETRY_WARNING =
          "ChatGPT encountered a temporary provider error and is retrying this turn."

        class << self
          def connection
            connection_mutex.synchronize do
              @connection ||= Connection.new
            end
          end

          def connection=(value)
            connection_mutex.synchronize { @connection = value }
          end

          def status
            connection.status
          end

          def passive_status
            connection.passive_status
          end

          def authenticate_async
            connection.authenticate_async
          end

          def discover_models(working_dir: Dir.pwd)
            connection.discover_models(working_dir: working_dir)
          end

          def shutdown
            existing = connection_mutex.synchronize do
              value = @connection
              @connection = nil
              value
            end
            existing&.close
          end

          def rejected_permission_response(params)
            options = Array(params && params["options"])
            rejection = options.find { |option| option["kind"].to_s == "reject_once" }
            if rejection
              {
                "outcome" => {
                  "outcome" => "selected",
                  "optionId" => rejection["optionId"]
                }
              }
            else
              { "outcome" => { "outcome" => "cancelled" } }
            end
          end

          private def connection_mutex
            @connection_mutex ||= Mutex.new
          end
        end

        def initialize(context: nil, persisted_state: nil, purpose: nil,
                       connection: nil, **_options)
          @context = context || {}
          @purpose = purpose && purpose.to_sym
          @connection = connection || self.class.connection
          @persisted_session_id = value(persisted_state, "session_id")
          @saved_model = value(persisted_state, "model")
          @saved_reasoning_effort = value(persisted_state, "reasoning_effort")
          @default_model = value(@context, "default_model")
          @external_session_id = @persisted_session_id.to_s
          @external_session_id = nil if @external_session_id.empty?
          @config_options = []
          @client_generation = nil
          @session_ready = false
          @active_generation = nil
          @state_mutex = Mutex.new
          @run_mutex = Mutex.new
          @run_condition = ConditionVariable.new
          @in_flight = false
          @turn_sequence = 0
          @active_turn_token = nil
          @active_client = nil
          @active_client_generation = nil
          @cancel_watchdog_token = nil
          @cancel_requested = false
          @prompt_visible = false
          @prompt_sent = false
          @cancel_notified = false
          @closed = false
          @tools = {}
        end

        def health
          @connection.health
        end

        def discover_models(working_dir: nil)
          @connection.discover_models(
            working_dir: working_dir || @context[:working_dir] || Dir.pwd
          )
        end

        def capabilities
          {
            cancel: true,
            image_input: true,
            plans: true,
            time_machine: false,
            sub_model: false,
            model_selection: true,
            fork: false
          }
        end

        # ACP owns the model catalog for an opened session. Keep this as a
        # runtime-native capability rather than treating it as an API-provider
        # sub-model overlay.
        def model_options
          option = config_option("model")
          return [] unless option

          flatten_options(option["options"]).filter_map do |candidate|
            value = candidate["value"].to_s.strip
            value unless value.empty?
          end.uniq
        end

        def set_model(model_name)
          requested = model_name.to_s.strip
          raise Error, "ChatGPT model selection requires a model" if requested.empty?

          @run_mutex.synchronize do
            raise Error, "ChatGPT runtime is closed" if @closed
            if @in_flight
              raise Clacky::RuntimeSession::BusyError,
                    "ChatGPT model cannot change during an in-flight prompt"
            end

            client = connected_client
            unless client && external_session_id && session_ready?
              raise Error, "ChatGPT model selection is unavailable until the session starts"
            end

            option = config_option("model")
            unless option && advertised_value?(option, requested)
              raise Error, "ChatGPT model was not advertised for this session"
            end
            return true if option["currentValue"].to_s == requested

            set_config_value(client, "model", requested)
          end
          true
        end

        def run(input, generation:)
          reserved = false
          connection_turn = false
          prompt_sent = false
          client = nil
          turn_token = reserve_turn!
          reserved = true
          if @connection.respond_to?(:begin_turn)
            @connection.begin_turn(self)
            connection_turn = true
          end
          @state_mutex.synchronize { @active_generation = generation.to_i }
          client = ensure_external_session(turn_token)
          raise TurnCancelled if turn_cancelled?

          prompt = build_prompt(input, client)
          session_id = external_session_id
          begin
            result = client.request(
              "session/prompt",
              { "sessionId" => session_id, "prompt" => prompt },
              timeout: nil,
              before_send: lambda do
                mark_prompt_visible(turn_token)
              end,
              on_sent: lambda do
                prompt_sent = true
                mark_prompt_sent(client, session_id, turn_token)
              end,
              on_send_error: lambda do
                mark_prompt_send_failed(turn_token)
              end
            )
          ensure
            mark_prompt_finished(turn_token)
          end
          usage_event = normalize_prompt_usage(result["usage"])
          emit_event(generation, usage_event) if usage_event
          raise TurnCancelled if turn_cancelled?

          {
            stop_reason: result["stopReason"],
            awaiting_user_feedback: false
          }
        rescue TurnCancelled
          discard_cancelled_external_session(client) unless prompt_sent
          { stop_reason: "cancelled", awaiting_user_feedback: false }
        rescue Clacky::Acp::Client::TransportError
          raise unless turn_cancelled?

          discard_cancelled_external_session(client)
          { stop_reason: "cancelled", awaiting_user_feedback: false }
        ensure
          if reserved
            close_external_session(client) if client && closed?
            @state_mutex.synchronize { @active_generation = nil }
            @run_mutex.synchronize do
              if @active_turn_token == turn_token
                @in_flight = false
                @active_turn_token = nil
                @active_client = nil
                @active_client_generation = nil
                @cancel_requested = false
                @prompt_visible = false
                @prompt_sent = false
                @prompt_waiting = false
                @cancel_notified = false
                @run_condition.broadcast
              end
            end
          end
          @connection.end_turn(self) if connection_turn &&
                                        @connection.respond_to?(:end_turn)
        end

        def cancel(reason:)
          turn_token = @run_mutex.synchronize do
            next false unless @in_flight

            @cancel_requested = true
            @run_condition.broadcast
            @active_turn_token
          end
          return false unless turn_token

          cancel_pending_confirmations
          session_id = external_session_id
          if session_id
            client = connected_client
            notify_cancel_if_ready(client, session_id)
          end
          schedule_cancel_watchdog(turn_token)
          true
        rescue StandardError
          !turn_token.nil? && turn_token != false
        end

        def close
          state = @run_mutex.synchronize do
            next nil if @closed

            @closed = true
            @cancel_requested = true if @in_flight
            @run_condition.broadcast
            { busy: @in_flight, turn_token: @active_turn_token }
          end
          return unless state

          cancel_pending_confirmations
          session_id = external_session_id
          @connection.unbind_session(self, session_id: session_id)
          connected_session_id = connected_external_session_id
          unless connected_session_id.nil?
            begin
              client = connected_client
              if !client
                clear_external_session(connected_session_id)
              elsif state[:busy]
                notify_cancel_if_ready(client, connected_session_id)
              else
                close_external_session(client, connected_session_id)
              end
            rescue StandardError
              nil
            end
          end
          schedule_cancel_watchdog(state[:turn_token]) if state[:busy]
          nil
        end

        def dump_state
          session_id = external_session_id
          return {} unless session_id

          state = { "session_id" => session_id }
          saved_model, saved_effort = @state_mutex.synchronize do
            [@saved_model, @saved_reasoning_effort]
          end
          model = current_config_value("model") || present_string(saved_model)
          effort = current_config_value("reasoning_effort") ||
                   present_string(saved_effort)
          state["model"] = model if model
          state["reasoning_effort"] = effort if effort
          state
        end

        def handle_session_update(params)
          update = params && params["update"]
          return unless update.is_a?(Hash)

          update_type = update["sessionUpdate"].to_s
          replace_config_options(update["configOptions"]) if update_type == "config_option_update"
          event_or_events = normalize_update(update_type, update)
          return unless event_or_events

          generation = @state_mutex.synchronize do
            @closed ? nil : @active_generation
          end
          events = event_or_events.is_a?(Array) ? event_or_events : [event_or_events]
          events.each { |event| emit_event(generation, event) } if generation
        end

        def handle_permission_request(params)
          return cancelled_permission_response unless permission_request_allowed?

          options = Array(params && params["options"])
          allow = options.find { |option| option["kind"].to_s == "allow_once" }
          reject = options.find { |option| option["kind"].to_s == "reject_once" }
          ui = @context[:ui]
          answer = if @context[:permission_mode].to_s == "auto_approve"
                     true
                   elsif ui&.respond_to?(:request_confirmation)
                     ui.request_confirmation(permission_prompt(params), default: false)
                   else
                     false
                   end
          unless permission_request_allowed?
            return cancelled_permission_response
          end
          return cancelled_permission_response if answer.to_s == "cancelled"

          selected = answer == true ? allow : reject
          if selected
            {
              "outcome" => {
                "outcome" => "selected",
                "optionId" => selected["optionId"]
              }
            }
          else
            cancelled_permission_response
          end
        rescue StandardError
          if permission_request_allowed?
            self.class.rejected_permission_response(params)
          else
            cancelled_permission_response
          end
        end

        private def reserve_turn!
          @run_mutex.synchronize do
            raise Error, "ChatGPT runtime is closed" if @closed
            raise BusyError, "ChatGPT session already has an in-flight prompt" if @in_flight

            @in_flight = true
            @turn_sequence += 1
            @active_turn_token = @turn_sequence
            @active_client = nil
            @active_client_generation = nil
            @cancel_requested = false
            @prompt_visible = false
            @prompt_sent = false
            @prompt_waiting = false
            @cancel_notified = false
            @run_condition.broadcast
            @active_turn_token
          end
        end

        private def turn_cancelled?
          @run_mutex.synchronize { @cancel_requested || @closed }
        end

        private def permission_request_allowed?
          @run_mutex.synchronize do
            @in_flight && @prompt_visible && !@cancel_requested && !@closed
          end
        end

        private def closed?
          @run_mutex.synchronize { @closed }
        end

        private def mark_prompt_visible(turn_token)
          @run_mutex.synchronize do
            return unless @active_turn_token == turn_token

            @prompt_visible = true
            @run_condition.broadcast
          end
        end

        private def mark_prompt_sent(client, session_id, turn_token)
          cancelled = @run_mutex.synchronize do
            next false unless @active_turn_token == turn_token

            @prompt_visible = true
            @prompt_sent = true
            @prompt_waiting = true
            @run_condition.broadcast
            @cancel_requested || @closed
          end
          notify_cancel_if_ready(client, session_id)
          schedule_cancel_watchdog(turn_token) if cancelled
        end

        private def mark_prompt_send_failed(turn_token)
          @run_mutex.synchronize do
            return unless @active_turn_token == turn_token

            @prompt_visible = false
            @prompt_sent = false
            @prompt_waiting = false
            @run_condition.broadcast
          end
        end

        private def mark_prompt_finished(turn_token)
          @run_mutex.synchronize do
            next unless @active_turn_token == turn_token

            @prompt_visible = false
            @prompt_waiting = false
            @run_condition.broadcast
          end
        end

        private def notify_cancel_if_ready(client, session_id)
          should_notify = @run_mutex.synchronize do
            next false unless @in_flight && @prompt_sent
            next false unless @cancel_requested || @closed
            next false if @cancel_notified

            @cancel_notified = true
            true
          end
          return false unless should_notify

          client.notify("session/cancel", "sessionId" => session_id)
          true
        rescue StandardError
          @run_mutex.synchronize { @cancel_notified = false }
          false
        end

        private def schedule_cancel_watchdog(turn_token)
          return unless turn_token

          spawn = @run_mutex.synchronize do
            next false unless cancelled_turn_locked?(turn_token)
            next false if @cancel_watchdog_token == turn_token

            @cancel_watchdog_token = turn_token
            true
          end
          return false unless spawn

          spawn_thread("codex-acp-cancel-watchdog") do
            watch_cancelled_turn(turn_token)
          end
          true
        end

        private def watch_cancelled_turn(turn_token)
          deadline = monotonic_now + CANCEL_GRACE
          target = nil
          loop do
            cancel_pending_confirmations
            state = @run_mutex.synchronize do
              unless cancelled_turn_locked?(turn_token)
                next [:done]
              end

              remaining = deadline - monotonic_now
              if remaining.positive?
                @run_condition.wait(@run_mutex, remaining)
                next [:wait]
              end
              if @active_client && @active_client_generation
                next [:restart, @active_client, @active_client_generation]
              end

              # Client startup is itself bounded, but may still be crossing its
              # initialize request when cancellation arrives. Wait for the exact
              # client/generation pair rather than restarting an unrelated one.
              @run_condition.wait(@run_mutex, CONTROL_TIMEOUT)
              [:wait]
            end
            break if state.first == :done
            if state.first == :restart
              target = state.drop(1)
              break
            end
          end

          while target && @connection.respond_to?(:restart_if_generation)
            restarted = @connection.restart_if_generation(
              target[0], target[1], requester: self
            )
            if restarted
              cancel_pending_confirmations
              break
            end

            target = @run_mutex.synchronize do
              next nil unless cancelled_turn_locked?(turn_token)

              @run_condition.wait(@run_mutex, CANCEL_GRACE)
              next nil unless cancelled_turn_locked?(turn_token)

              [@active_client, @active_client_generation]
            end
          end
        ensure
          @run_mutex.synchronize do
            @cancel_watchdog_token = nil if @cancel_watchdog_token == turn_token
          end
        end

        private def cancelled_turn_locked?(turn_token)
          @in_flight && @active_turn_token == turn_token &&
            (@cancel_requested || @closed)
        end

        private def remember_turn_client(client, generation, turn_token)
          @run_mutex.synchronize do
            return unless @in_flight && @active_turn_token == turn_token

            @active_client = client
            @active_client_generation = generation
            @run_condition.broadcast
          end
        end

        private def spawn_thread(name, &block)
          Clacky::ThreadRegistry.spawn(name: name, daemon: true, &block)
        end

        private def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        private def cancel_pending_confirmations
          ui = @context[:ui]
          return unless ui&.respond_to?(:cancel_pending_confirmations)

          ui.cancel_pending_confirmations(result: "cancelled")
        end

        private def discard_opened_session_if_closed!(client, session_id)
          return unless closed?

          close_external_session(client, session_id)
          raise TurnCancelled
        end

        private def discard_cancelled_external_session(client)
          session_id = external_session_id
          return unless session_id

          @connection.unbind_session(self, session_id: session_id)
          begin
            if client
              client.request(
                "session/close",
                { "sessionId" => session_id },
                timeout: CONTROL_TIMEOUT
              )
            end
          rescue StandardError
            nil
          ensure
            clear_external_session(session_id)
          end
        end

        private def close_external_session(client, session_id = nil)
          target = session_id || external_session_id
          return unless target

          @connection.unbind_session(self, session_id: target)
          client.request(
            "session/close", { "sessionId" => target }, timeout: CONTROL_TIMEOUT
          )
        rescue StandardError
          nil
        ensure
          @state_mutex.synchronize do
            if @external_session_id.to_s == target.to_s
              @external_session_id = nil
              @client_generation = nil
              @session_ready = false
            end
          end if target
        end

        private def cancelled_permission_response
          { "outcome" => { "outcome" => "cancelled" } }
        end

        private def permission_prompt(params)
          request = params.is_a?(Hash) ? params : {}
          tool_call = request["toolCall"].is_a?(Hash) ? request["toolCall"] : {}
          raw_input = tool_call["rawInput"].is_a?(Hash) ? tool_call["rawInput"] : {}
          title = tool_call["title"].to_s.strip
          title = "Allow this ChatGPT action?" if title.empty?
          lines = [title]
          append_permission_detail(lines, "Command", raw_input["command"])
          append_permission_detail(lines, "Working directory", raw_input["cwd"])
          %w[path paths url host network].each do |key|
            append_permission_detail(lines, key.tr("_", " ").capitalize, raw_input[key])
          end
          locations = tool_call["locations"] || request["locations"]
          append_permission_detail(lines, "Locations", locations)
          description = request.dig("_meta", "permission", "description")
          append_permission_detail(lines, "Reason", description)
          lines.join("\n").byteslice(0, 4096).to_s.force_encoding(Encoding::UTF_8).scrub
        end

        private def append_permission_detail(lines, label, value)
          return if value.nil? || (value.respond_to?(:empty?) && value.empty?)

          rendered = value.is_a?(String) ? value : JSON.generate(value)
          rendered = rendered.to_s.gsub(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/, " ")
          rendered = rendered.byteslice(0, 2048).to_s.force_encoding(Encoding::UTF_8).scrub
          lines << "#{label}: #{rendered}"
        rescue JSON::GeneratorError
          nil
        end

        private def ensure_external_session(turn_token)
          client, generation = @connection.client_with_generation
          if @connection.respond_to?(:workspace_allowed?) &&
             !@connection.workspace_allowed?(@context[:working_dir] || Dir.pwd)
            raise Error, "ChatGPT workspace overlaps a protected credential path"
          end
          remember_turn_client(client, generation, turn_token)
          if connected_to_generation?(generation)
            configure_open_session(client, generation) unless session_ready?
            return client
          end

          old_session_id = external_session_id
          if old_session_id && !reserve_external_session(old_session_id)
            emit_event(
              active_generation,
              type: :warning,
              code: "resume_conflict",
              content: RESUME_CONFLICT_WARNING
            )
            @state_mutex.synchronize do
              @external_session_id = nil
              @client_generation = nil
              @session_ready = false
            end
            old_session_id = nil
          end
          if old_session_id
            begin
              response = client.request(
                "session/resume",
                session_open_params(old_session_id),
                timeout: nil
              )
              discard_opened_session_if_closed!(client, old_session_id)
              accept_opened_session(client, generation, old_session_id, response)
              configure_open_session(client, generation)
              return client
            rescue Clacky::Acp::Client::ProtocolError => e
              raise unless missing_resumed_session?(e, old_session_id)

              emit_event(
                active_generation,
                type: :warning,
                code: "resume_failed",
                content: RESUME_FAILED_WARNING
              )
              clear_external_session(old_session_id)
            end
          end

          response = client.request(
            "session/new", session_open_params, timeout: nil
          )
          session_id = response["sessionId"].to_s
          raise Error, "Codex ACP did not return a session id" if session_id.empty?

          discard_opened_session_if_closed!(client, session_id)
          accept_opened_session(client, generation, session_id, response,
                                previous_session_id: old_session_id)
          configure_open_session(client, generation)
          client
        end

        private def missing_resumed_session?(error, session_id)
          return false unless error.method.to_s == "session/resume"
          return true if error.code.to_i == -32_002
          return false unless error.code.to_i == -32_603
          return false unless error.remote_message == "Internal error"
          return false unless error.data.is_a?(Hash)

          error.data["details"] == "#{MISSING_ROLLOUT_ERROR_PREFIX}#{session_id}"
        end

        private def connected_to_generation?(generation)
          @state_mutex.synchronize do
            @client_generation.to_i == generation.to_i && !@external_session_id.nil?
          end
        end

        private def session_ready?
          @state_mutex.synchronize { @session_ready }
        end

        private def configure_open_session(client, generation)
          return false if turn_cancelled?

          apply_permission_mode(client)
          return false if turn_cancelled?

          restore_effective_configuration(client)
          @state_mutex.synchronize do
            if @client_generation.to_i == generation.to_i && @external_session_id
              @session_ready = true
            end
          end
          true
        end

        private def session_open_params(session_id = nil)
          params = {
            "cwd" => File.expand_path(@context[:working_dir] || Dir.pwd),
            "mcpServers" => []
          }
          params["sessionId"] = session_id if session_id
          params
        end

        private def accept_opened_session(client, generation, session_id, response,
                                          previous_session_id: nil)
          bound = @connection.bind_session(
            self, session_id, previous_session_id: previous_session_id
          )
          raise Error, "Codex ACP session is already owned locally" unless bound

          @state_mutex.synchronize do
            @external_session_id = session_id
            @client_generation = generation
            @session_ready = false
          end

          replace_config_options(response["configOptions"])
        end

        private def reserve_external_session(session_id)
          if @connection.respond_to?(:reserve_session)
            @connection.reserve_session(self, session_id)
          else
            @connection.bind_session(self, session_id)
          end
        end

        private def connected_external_session_id
          @state_mutex.synchronize do
            @client_generation ? @external_session_id : nil
          end
        end

        private def connected_client
          generation = @state_mutex.synchronize { @client_generation }
          return nil unless generation
          if @connection.respond_to?(:client_for_generation)
            return @connection.client_for_generation(generation)
          end

          client, current_generation = @connection.client_with_generation
          current_generation.to_i == generation.to_i ? client : nil
        end

        private def clear_external_session(session_id)
          @connection.unbind_session(self, session_id: session_id)
          @state_mutex.synchronize do
            if @external_session_id.to_s == session_id.to_s
              @external_session_id = nil
              @client_generation = nil
              @session_ready = false
            end
          end
        end

        private def restore_effective_configuration(client)
          saved_model, saved_effort, default_model = @state_mutex.synchronize do
            [@saved_model, @saved_reasoning_effort, @default_model]
          end
          apply_saved_config_value(
            client,
            "model",
            present_string(saved_model) || present_string(default_model)
          )
          apply_saved_config_value(
            client, "reasoning_effort", saved_effort
          )
          @state_mutex.synchronize do
            @saved_model = nil if @saved_model == saved_model
            if @saved_reasoning_effort == saved_effort
              @saved_reasoning_effort = nil
            end
          end
        end

        private def apply_saved_config_value(client, config_id, saved_value)
          value_to_apply = saved_value.to_s
          return if value_to_apply.empty?

          option = config_option(config_id)
          return unless option && advertised_value?(option, value_to_apply)
          return if option["currentValue"].to_s == value_to_apply

          set_config_value(client, config_id, value_to_apply)
        end

        private def apply_permission_mode(client)
          requested = @context[:permission_mode].to_s
          target = case requested
                   when "auto_approve"
                     "agent"
                   when "confirm_all", "confirm_edits", "confirm_safes"
                     "read-only"
                   end
          return unless target

          option = config_option("mode")
          return unless option && advertised_value?(option, target)
          return if option["currentValue"].to_s == target

          set_config_value(client, "mode", target)
        end

        private def set_config_value(client, config_id, value_to_apply)
          response = client.request(
            "session/set_config_option",
            {
              "sessionId" => external_session_id,
              "configId" => config_id,
              "value" => value_to_apply
            },
            timeout: CONTROL_TIMEOUT
          )
          replace_config_options(response["configOptions"])
        end

        private def advertised_value?(option, requested)
          flatten_options(option["options"]).any? do |candidate|
            candidate["value"].to_s == requested.to_s
          end
        end

        private def flatten_options(options)
          Array(options).each_with_object([]) do |entry, flattened|
            next unless entry.is_a?(Hash)

            if entry["options"].is_a?(Array)
              flattened.concat(flatten_options(entry["options"]))
            else
              flattened << entry
            end
          end
        end

        private def replace_config_options(options)
          return unless options.is_a?(Array)

          copy = deep_copy(options.select { |option| option.is_a?(Hash) })
          @state_mutex.synchronize { @config_options = copy }
        end

        private def config_option(config_id)
          @state_mutex.synchronize do
            option = @config_options.find { |entry| entry["id"].to_s == config_id }
            option && deep_copy(option)
          end
        end

        private def current_config_value(config_id)
          option = config_option(config_id)
          value = option && option["currentValue"]
          string = value.to_s.strip
          string.empty? ? nil : string
        end

        private def present_string(value)
          string = value.to_s.strip
          string.empty? ? nil : string
        end

        private def build_prompt(input, client)
          blocks = []
          content = input.content.to_s
          blocks << { "type" => "text", "text" => content } unless content.empty?
          Array(input.reference_contexts).each do |reference|
            text = reference.is_a?(String) ? reference : JSON.generate(reference)
            blocks << { "type" => "text", "text" => "[Reference context]\n#{text}" }
          end

          files = Array(input.files)
          unless files.empty?
            supports_images = client.agent_capabilities.dig(
              "promptCapabilities", "image"
            ) == true
            files.each do |file|
              image = image_block(file)
              if image
                raise UnsupportedInput, "Codex ACP does not support image input" unless supports_images

                blocks << image
              else
                resource_link = resource_link_block(file)
                unless resource_link
                  raise UnsupportedInput, "Codex ACP cannot represent this attachment"
                end

                blocks << resource_link
              end
            end
          end
          blocks
        rescue JSON::GeneratorError
          raise UnsupportedInput, "Codex ACP cannot represent the supplied context"
        end

        private def image_block(file)
          return nil unless file.is_a?(Hash)

          data_url = (file["data_url"] || file[:data_url]).to_s
          match = data_url.match(/\Adata:([^;,]+);base64,(.*)\z/m)
          return nil unless match && match[1].start_with?("image/")

          {
            "type" => "image",
            "mimeType" => match[1],
            "data" => match[2]
          }
        end

        private def resource_link_block(file)
          return nil unless file.is_a?(Hash)

          path = value(file, "path").to_s
          return nil if path.empty?

          absolute_path = File.expand_path(path, @context[:working_dir] || Dir.pwd)
          return nil unless File.exist?(absolute_path)

          escaped_path = URI::DEFAULT_PARSER.escape(absolute_path)
          block = {
            "type" => "resource_link",
            "name" => value(file, "name").to_s,
            "uri" => URI::Generic.build(scheme: "file", path: escaped_path).to_s
          }
          block["name"] = File.basename(absolute_path) if block["name"].empty?
          mime_type = value(file, "mime_type").to_s
          mime_type = value(file, "type").to_s if mime_type.empty?
          block["mimeType"] = mime_type if mime_type.include?("/")
          block["size"] = File.size(absolute_path) if File.file?(absolute_path)
          block
        rescue ArgumentError, URI::InvalidURIError
          nil
        end

        private def normalize_update(update_type, update)
          case update_type
          when "agent_message_chunk"
            {
              type: :assistant_delta,
              message_id: update["messageId"] || "assistant",
              content: content_text(update["content"])
            }
          when "agent_thought_chunk"
            { type: :thought, content: bounded_text(content_text(update["content"])) }
          when "tool_call"
            normalize_tool_call(update)
          when "tool_call_update"
            normalize_tool_update(update)
          when "plan"
            { type: :plan, entries: normalize_plan_entries(update["entries"]) }
          when "plan_update"
            plan = update["plan"].is_a?(Hash) ? update["plan"] : {}
            {
              type: :plan,
              entries: normalize_plan_entries(plan["entries"]),
              plan_id: plan["planId"],
              content: bounded_text(plan["content"]),
              plan: deep_copy(plan)
            }
          when "usage_update"
            {
              type: :usage,
              used: update["used"],
              size: update["size"],
              cost: deep_copy(update["cost"])
            }
          when "session_info_update"
            info = {
              type: :session_info,
              title: update["title"],
              updated_at: update["updatedAt"]
            }
            retry_warning = normalize_codex_retry_warning(update)
            retry_warning ? [info, retry_warning] : info
          when "config_option_update"
            nil
          else
            { type: :unknown, session_update: update_type }
          end
        end

        private def normalize_codex_retry_warning(update)
          error = update.dig("_meta", "codex", "error")
          return nil unless error.is_a?(Hash) && error["willRetry"] == true

          {
            type: :warning,
            code: "codex_retry",
            content: CODEX_RETRY_WARNING
          }
        end

        private def normalize_tool_update(update)
          id = update["toolCallId"].to_s
          current = @tools[id] || {}
          merged = current.merge(deep_copy(update))
          @tools[id] = merged
          if terminal_tool_status?(merged)
            @tools.delete(id)
            tool_result_event(merged)
          else
            tool_call_event(merged)
          end
        end

        private def normalize_tool_call(update)
          id = update["toolCallId"].to_s
          @tools[id] = deep_copy(update)
          call = tool_call_event(update)
          return call unless terminal_tool_status?(update)

          @tools.delete(id)
          [call, tool_result_event(update)]
        end

        private def terminal_tool_status?(update)
          %w[completed failed].include?(update["status"].to_s)
        end

        private def tool_result_event(update)
          raw_result = if update.key?("rawOutput")
                         update["rawOutput"]
                       else
                         update["content"]
                       end
          result, exit_code = normalize_tool_output(raw_result)
          status = update["status"].to_s
          status = "failed" if exit_code && exit_code != 0
          status = nil if status.empty?
          {
            type: :tool_result,
            tool_call_id: update["toolCallId"].to_s,
            result: result,
            status: status,
            exit_code: exit_code
          }
        end

        private def normalize_tool_output(raw_result)
          exit_code = nil
          rendered = raw_result
          if raw_result.is_a?(Hash)
            rendered = value(raw_result, "formatted_output") ||
                       value(raw_result, "formattedOutput") ||
                       value(raw_result, "output") ||
                       value(raw_result, "content")
            raw_exit_code = value(raw_result, "exit_code") ||
                            value(raw_result, "exitCode")
            exit_code = Integer(raw_exit_code) unless raw_exit_code.nil?
            rendered = JSON.generate(raw_result) if rendered.nil?
          elsif !raw_result.nil? && !raw_result.is_a?(String)
            rendered = JSON.generate(raw_result)
          end
          [rendered.to_s, exit_code]
        rescue ArgumentError, TypeError, JSON::GeneratorError
          [raw_result.to_s, nil]
        end

        private def tool_call_event(update)
          {
            type: :tool_call,
            tool_call_id: update["toolCallId"].to_s,
            name: update["name"] || update["title"] || update["kind"] || "tool",
            input: deep_copy(update["rawInput"] || {})
          }
        end

        private def normalize_plan_entries(entries)
          Array(entries).each_with_object([]) do |entry, result|
            next unless entry.is_a?(Hash)

            result << {
              "task" => value(entry, "content") || value(entry, "task"),
              "priority" => value(entry, "priority"),
              "status" => value(entry, "status")
            }
          end
        end

        private def normalize_prompt_usage(usage)
          return nil unless usage.is_a?(Hash)

          prompt_tokens = usage_value(usage, "inputTokens", "input_tokens")
          completion_tokens = usage_value(usage, "outputTokens", "output_tokens")
          cache_read = usage_value(usage, "cachedReadTokens", "cached_read_tokens")
          cache_write = usage_value(usage, "cachedWriteTokens", "cached_write_tokens")
          total_tokens = usage_value(usage, "totalTokens", "total_tokens")
          if total_tokens.nil? && (!prompt_tokens.nil? || !completion_tokens.nil?)
            total_tokens = prompt_tokens.to_i + completion_tokens.to_i
          end
          return nil if total_tokens.nil? && prompt_tokens.nil? && completion_tokens.nil?

          {
            type: :usage,
            prompt_tokens: prompt_tokens.to_i,
            completion_tokens: completion_tokens.to_i,
            cache_read: cache_read.to_i,
            cache_write: cache_write.to_i,
            total_tokens: total_tokens.to_i,
            delta_tokens: total_tokens.to_i
          }
        end

        private def usage_value(usage, *keys)
          keys.each do |key|
            return usage[key] if usage.key?(key)
            return usage[key.to_sym] if usage.key?(key.to_sym)
          end
          nil
        end

        private def content_text(content)
          return "" unless content.is_a?(Hash)
          return content["text"].to_s if content["type"] == "text"

          resource = content["resource"]
          resource.is_a?(Hash) ? resource["text"].to_s : ""
        end

        private def bounded_text(text)
          value = text.to_s
          return value if value.bytesize <= MAX_THOUGHT_BYTES

          value.byteslice(0, MAX_THOUGHT_BYTES).to_s.force_encoding(Encoding::UTF_8).scrub
        end

        private def emit_event(generation, event)
          sink = @context[:event_sink]
          sink.call(generation, event) if generation && sink.respond_to?(:call)
        end

        private def active_generation
          @state_mutex.synchronize { @active_generation }
        end

        private def external_session_id
          @state_mutex.synchronize { @external_session_id }
        end

        private def value(hash, key)
          return nil unless hash.is_a?(Hash)

          hash[key] || hash[key.to_sym]
        end

        private def deep_copy(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, item), copy|
              copy[deep_copy(key)] = deep_copy(item)
            end
          when Array
            value.map { |item| deep_copy(item) }
          else
            begin
              value.dup
            rescue TypeError
              value
            end
          end
        end
      end
    end
  end
end
