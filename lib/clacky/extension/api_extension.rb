# frozen_string_literal: true

require "json"
require "fileutils"

module Clacky
  # Base class for HTTP API extensions declared in an ext.yml container as
  # `contributes.api: <path/to/handler.rb>`. Subclasses use a tiny route DSL
  # (get/post/put/patch/delete) to expose endpoints under
  #   /api/ext/<ext_id>/<sub-path>
  #
  # The framework wires up access-key auth, timeouts, JSON error envelopes,
  # path-parameter parsing, and a curated handler context — extension authors
  # only fill in business logic.
  #
  # Minimal example (~/.clacky/ext/local/my-dashboard/api/handler.rb):
  #
  #   class MyDashboardExt < Clacky::ApiExtension
  #     get "/summary" do
  #       json(sessions: session_manager.list.size)
  #     end
  #   end
  #
  # Mounted automatically at: GET /api/ext/my-dashboard/summary
  class ApiExtension
    HTTP_METHODS = %i[get post put patch delete].freeze
    MAX_TIMEOUT  = 600
    DEFAULT_TIMEOUT = 10

    Route = Struct.new(:method, :pattern, :regex, :param_names, :block, :options, keyword_init: true)

    class Halt < StandardError
      attr_reader :status, :payload, :content_type, :extra_headers

      def initialize(status, payload, content_type, extra_headers: {})
        super("api_ext halt #{status}")
        @status       = status
        @payload      = payload
        @content_type = content_type
        @extra_headers = extra_headers
      end
    end

    class << self
      # Keyed by ext_id — every extension contributes at most one API unit
      # (declared as `contributes.api: <path>` in ext.yml).
      def registry
        @registry ||= {}
      end

      def register(ext_id, klass)
        registry[ext_id] = klass
      end

      def reset_registry!
        @registry = {}
        @pending_subclasses = []
      end

      # Captures every subclass at the moment its `class` body finishes being
      # required — the loader pops the most recent one off this list to bind
      # an ext_id/dir without relying on ObjectSpace scans.
      def pending_subclasses
        @pending_subclasses ||= []
      end

      def inherited(subclass)
        super
        Clacky::ApiExtension.pending_subclasses << subclass
      end

      # Per-subclass state — inherited classes carry their own routes/options.
      def routes
        @routes ||= []
      end

      def class_timeout
        @class_timeout
      end

      def public_paths
        @public_paths ||= []
      end

      # Clears accumulated route/public-path state so a force-reload (`load`) of
      # a named-constant handler re-registers its routes from scratch instead of
      # appending duplicates onto the reopened class.
      def reset_routes!
        @routes = []
        @public_paths = []
      end

      def ext_id
        @ext_id
      end

      def ext_id=(value)
        @ext_id = value
      end

      def ext_dir
        @ext_dir
      end

      def ext_dir=(value)
        @ext_dir = value
      end

      def meta
        @meta ||= {}
      end

      def meta=(value)
        @meta = value || {}
      end

      # Set a default timeout (seconds) for every handler in this class.
      # Per-route override available via `get "/x", timeout: 30 do ... end`.
      def timeout(seconds)
        raise ArgumentError, "timeout must be > 0" unless seconds.is_a?(Numeric) && seconds > 0
        raise ArgumentError, "timeout exceeds MAX_TIMEOUT (#{MAX_TIMEOUT}s)" if seconds > MAX_TIMEOUT

        @class_timeout = seconds.to_f
      end

      # Mark a route as not requiring access-key auth. Caller must also
      # declare `public: true` at ext.yml top level for the framework to honor this.
      def public_endpoint(pattern)
        public_paths << normalize_pattern(pattern)
      end

      HTTP_METHODS.each do |verb|
        define_method(verb) do |pattern, **opts, &block|
          raise ArgumentError, "missing handler block for #{verb.upcase} #{pattern}" unless block

          per_route_timeout = opts[:timeout]
          if per_route_timeout
            raise ArgumentError, "timeout must be > 0" unless per_route_timeout.is_a?(Numeric) && per_route_timeout > 0
            raise ArgumentError, "timeout exceeds MAX_TIMEOUT (#{MAX_TIMEOUT}s)" if per_route_timeout > MAX_TIMEOUT
          end

          normalized = normalize_pattern(pattern)
          regex, param_names = compile_pattern(normalized)
          routes << Route.new(
            method:      verb,
            pattern:     normalized,
            regex:       regex,
            param_names: param_names,
            block:       block,
            options:     opts.dup
          )
        end
      end

      def normalize_pattern(pattern)
        pattern = pattern.to_s
        pattern = "/#{pattern}" unless pattern.start_with?("/")
        pattern = pattern.chomp("/")
        pattern.empty? ? "/" : pattern
      end

      def compile_pattern(pattern)
        param_names = []
        regex_str = pattern.gsub(%r{:([a-zA-Z_][a-zA-Z0-9_]*)}) do |_match|
          param_names << Regexp.last_match(1).to_sym
          "([^/]+)"
        end
        [Regexp.new("\\A#{regex_str}\\z"), param_names]
      end
    end

    attr_reader :req, :res, :route, :params

    def initialize(req:, res:, route:, params:, http_server:)
      @req         = req
      @res         = res
      @route       = route
      @params      = params
      @http_server = http_server
    end

    def invoke
      instance_exec(&route.block)
    end

    # ---- handler context (white-listed access to host process) ----

    def json(*args, **kwargs)
      if args.empty?
        # Treat kwargs as the body: json(foo: 1, bar: 2)
        # For non-200 status, pass an explicit hash: json({foo: 1}, status: 422)
        raise Halt.new(200, JSON.generate(kwargs), "application/json; charset=utf-8")
      elsif args.size == 1
        status = kwargs[:status] || 200
        raise Halt.new(status, JSON.generate(args[0]), "application/json; charset=utf-8")
      else
        raise ArgumentError, "json: expected (hash) or (key: value, ...)"
      end
    end

    def text(str, status: 200)
      raise Halt.new(status, str.to_s, "text/plain; charset=utf-8")
    end

    def send_data(bytes, content_type:, filename: nil, status: 200)
      disposition = filename ? "attachment; filename=\"#{filename}\"" : "attachment"
      raise Halt.new(status, bytes, content_type, extra_headers: {
        "Content-Disposition" => disposition,
        "Content-Length"      => bytes.bytesize.to_s
      })
    end

    def error!(message, status: 400, **extra)
      payload = { error: message.to_s }
      payload.merge!(extra) unless extra.empty?
      raise Halt.new(status, JSON.generate(payload), "application/json; charset=utf-8")
    end

    def json_body
      @json_body ||= begin
        return {} if req.body.nil? || req.body.empty?
        JSON.parse(req.body)
      rescue JSON::ParserError
        {}
      end
    end

    def query
      @query ||= req.query || {}
    end

      def data_path(*parts)
        base = Clacky::ExtensionLoader.data_dir_for(self.class.ext_id)
        FileUtils.mkdir_p(base)
        File.join(base, *parts.map(&:to_s))
      end
    def ext_dir
      self.class.ext_dir
    end

    def ext_id
      self.class.ext_id
    end

    def config
      self.class.meta["config"] || {}
    end

    def session_manager
      @http_server&.instance_variable_get(:@session_manager)
    end

    def agent_config
      @http_server&.instance_variable_get(:@agent_config)
    end

    def registry
      @http_server&.instance_variable_get(:@registry)
    end

    # Create a brand-new session and optionally kick off its first task.
    # Returns the new session_id. When a prompt is given, the task is
    # submitted immediately (the session starts running); display_message
    # controls the user-facing bubble shown in place of the raw prompt.
    def create_session(name: nil, prompt: nil, working_dir: nil, profile: "general",
                       source: :manual, display_message: nil)
      error!("server not ready", status: 503) unless @http_server

      session_id = @http_server.send(
        :build_session,
        name: name,
        working_dir: working_dir,
        profile: profile,
        source: source
      )

      submit_task(session_id, prompt, display_message: display_message) if prompt && !prompt.strip.empty?

      session_id
    end

    # Submit a prompt to an existing session for execution.
    # Returns the session_id on success.
    # Raises Halt (409) if the session is already running and `interrupt: false`.
    # When `interrupt: true`, supersedes the current turn (raises AgentInterrupted
    # on the running thread, waits up to 2s for it to exit) then runs the new task.
    def submit_task(session_id, prompt, display_message: nil, interrupt: false)
      reg = registry
      error!("server not ready", status: 503) unless reg

      unless reg.exist?(session_id)
        reg.ensure(session_id)
        error!("session not found: #{session_id}", status: 404) unless reg.exist?(session_id)
      end

      session = reg.get(session_id)
      if session[:status] == :running
        error!("session is busy", status: 409) unless interrupt
        @http_server.send(:interrupt_session, session_id)
        old_thread = nil
        reg.with_session(session_id) { |s| old_thread = s[:thread] }
        old_thread&.join(2)
      end

      @http_server.send(:run_session_task, session_id, prompt, display_message: display_message)
      session_id
    end

    # Run a one-off side task on an existing session's agent and return its
    # reply text SYNCHRONOUSLY, without polluting the main conversation.
    #
    # Unlike submit_task (which enqueues a turn into the live conversation and
    # returns immediately), this forks the session's agent — reusing its cached
    # context and unified billing — runs the task to completion on the fork, and
    # returns the fork's final reply. The main conversation is never touched.
    #
    # Strategy A (parent-busy → skip): if the session is currently running, or the
    # server is at its concurrency limit, this returns { busy: true } without
    # running. Callers (e.g. periodic analysis) should treat that as "try later".
    #
    # @param session_id [String]
    # @param prompt [String]
    # @param model [String, nil] "lite" for the lite companion, nil = current
    # @param forbidden_tools [Array<String>] tool names blocked in the fork
    # @return [Hash] { text: "..." } on success, or { busy: true } when skipped
    def dispatch_to_session(session_id, prompt, model: nil, forbidden_tools: [])
      reg = registry
      error!("server not ready", status: 503) unless reg

      unless reg.exist?(session_id)
        reg.ensure(session_id)
        error!("session not found: #{session_id}", status: 404) unless reg.exist?(session_id)
      end

      return { busy: true } if reg.respond_to?(:running_full?) && reg.running_full?

      session = reg.get(session_id)
      return { busy: true } if session[:status] == :running

      agent = session[:agent]
      error!("session agent not available", status: 503) unless agent

      { text: agent.run_detached(prompt, model: model, forbidden_tools: forbidden_tools) }
    end

    def server_start_time
      @http_server&.instance_variable_get(:@start_time)
    end

    def logger
      @logger ||= ScopedLogger.new(self.class.ext_id)
    end

    # Lightweight wrapper that prefixes log lines with the extension id.
    class ScopedLogger
      def initialize(ext_id)
        @prefix = "[api_ext:#{ext_id}]"
      end

      %i[debug info warn error].each do |level|
        define_method(level) do |msg|
          Clacky::Logger.public_send(level, "#{@prefix} #{msg}")
        end
      end
    end
  end
end
