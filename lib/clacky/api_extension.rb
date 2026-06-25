# frozen_string_literal: true

require "json"
require "fileutils"

module Clacky
  # Base class for user-defined HTTP API extensions loaded from
  # ~/.clacky/api_ext/<name>/handler.rb. Subclasses use a tiny route DSL
  # (get/post/put/patch/delete) to expose endpoints under
  #   /api/ext/<name>/<sub-path>
  #
  # The framework wires up access-key auth, timeouts, JSON error envelopes,
  # path-parameter parsing, and a curated handler context — extension authors
  # only fill in business logic.
  #
  # Minimal example (~/.clacky/api_ext/my-dashboard/handler.rb):
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
      attr_reader :status, :payload, :content_type

      def initialize(status, payload, content_type)
        super("api_ext halt #{status}")
        @status       = status
        @payload      = payload
        @content_type = content_type
      end
    end

    class << self
      # Registry of all loaded ApiExtension subclasses, keyed by extension id
      # (== directory name == mount prefix segment).
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
      # declare `public: true` in meta.yml for the framework to honor this.
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
      base = File.join(self.class.ext_dir, "data")
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
