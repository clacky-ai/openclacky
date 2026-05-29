# frozen_string_literal: true

require "json"
require "pathname"
require "monitor"

require_relative "client"
require_relative "virtual_skill"

module Clacky
  module Mcp
    # Central registry for MCP servers configured by the user.
    #
    # Responsibilities:
    #   - Load ~/.clacky/mcp.json (or project .clacky/mcp.json) on demand.
    #   - For each declared server, expose a VirtualSkill so the main agent
    #     sees it as a one-line capability in the AVAILABLE SKILLS section.
    #     No tool schemas leak into the main context.
    #   - Lazily spawn the server process the first time invoke_skill('mcp:xxx')
    #     happens, cache the connection, and reap idle servers after a timeout.
    #   - Provide a single call_tool entry point for Tools::McpCall to dispatch
    #     into.
    class Registry
      # User-facing config files, in priority order (later wins).
      # Resolved at load time (not at constant evaluation) so HOME changes — e.g.
      # in tests using stub_const or Dir.mktmpdir + ENV — are honored.
      private def global_config_paths
        [File.join(Dir.home, ".clacky", "mcp.json")]
      end

      # How long an MCP server may sit idle before we reap it. Vital for the
      # "no gateway" promise: we never keep stale processes around.
      DEFAULT_IDLE_TIMEOUT = 300  # 5 min

      # How long to wait for tools/list during cold metadata collection.
      DESCRIPTION_FETCH_TIMEOUT = 20

      attr_reader :servers

      def initialize(working_dir: nil, idle_timeout: DEFAULT_IDLE_TIMEOUT)
        @working_dir   = working_dir
        @idle_timeout  = idle_timeout
        @servers       = {}        # name => spec hash
        @clients       = {}        # name => Client (only when started)
        @virtual_skills_cache = nil
        @lock          = Monitor.new
        @reaper_thread = nil

        load_config
        start_reaper
      end

      # Reload mcp.json (e.g. user added a server) and invalidate caches.
      # Existing live clients survive; only stopped/removed servers get cleaned.
      def reload
        @lock.synchronize do
          old_names = @servers.keys
          @servers = {}
          load_config
          @virtual_skills_cache = nil

          (old_names - @servers.keys).each do |gone|
            @clients.delete(gone)&.stop
          end
        end
      end

      # Map of server name -> VirtualSkill. Cached because rebuilding it triggers
      # tools/list against every cold server, which we want to do at most once
      # per process.
      #
      # Implementation note: we do NOT pre-spawn servers here. We need their
      # tool list to populate the VirtualSkill body, but we only fetch it the
      # first time the *subagent* actually fires up. For the system-prompt
      # description we use the user-provided "description" field from mcp.json,
      # falling back to a placeholder. This keeps app startup zero-cost.
      def virtual_skills
        @lock.synchronize do
          return @virtual_skills_cache.values if @virtual_skills_cache

          @virtual_skills_cache = {}
          @servers.each do |name, spec|
            @virtual_skills_cache[name] = VirtualSkill.new(
              server_name: name,
              description: spec["description"] || default_description_for(name)
            )
          end
          @virtual_skills_cache.values
        end
      end

      # Return a fresh VirtualSkill for a server. The HttpServer's MCP tools
      # endpoint uses this to satisfy probe requests; tool schemas are no
      # longer attached to the skill itself — clients fetch them separately
      # via /api/mcp/:name/tools.
      # @param server_name [String]
      # @return [VirtualSkill, nil]
      def virtual_skill_for(server_name)
        return nil unless @servers.key?(server_name)

        spec = @servers[server_name]
        VirtualSkill.new(
          server_name: server_name,
          description: spec["description"] || default_description_for(server_name)
        )
      end

      # Fetch the live tool list (and lazily cold-start the server). Used by
      # the HttpServer for /api/mcp/:name/tools and /api/mcp/:name/probe.
      def tool_definitions(server_name)
        client = ensure_started(server_name)
        return [] unless client

        client.tool_definitions
      end

      # Execute a tool call against an MCP server. Used by Tools::McpCall.
      # @return [Hash] MCP `tools/call` result
      def call_tool(server_name, tool_name, arguments)
        client = ensure_started(server_name)
        raise Mcp::Client::TransportError, "MCP server '#{server_name}' is not configured" unless client

        client.call_tool(tool_name, arguments)
      end

      # Has the user configured any MCP servers?
      def any?
        !@servers.empty?
      end

      def configured?(server_name)
        @servers.key?(server_name)
      end

      # Stop all live MCP server processes. Safe to call from at_exit hooks
      # and on agent shutdown.
      def shutdown
        @lock.synchronize do
          @reaper_thread&.kill rescue nil
          @reaper_thread = nil
          @clients.each_value { |c| c.stop rescue nil }
          @clients.clear
        end
      end

      # Spawn (if needed) and return the client for a server. Returns nil if the
      # server is not configured. Raises Mcp::Client::TransportError if the
      # process refuses to start.
      private def ensure_started(server_name)
        spec = @servers[server_name]
        return nil unless spec

        @lock.synchronize do
          existing = @clients[server_name]
          return existing if existing&.started?

          client = Client.from_spec(server_name, spec)
          client.start
          @clients[server_name] = client
          client
        end
      end

      private def load_config
        paths = global_config_paths
        if @working_dir
          paths = paths + [File.join(@working_dir, ".clacky", "mcp.json")]
        end

        paths.each do |path|
          next unless File.exist?(path)

          begin
            data = JSON.parse(File.read(path))
          rescue JSON::ParserError => e
            Clacky::Logger.warn("Skipping malformed MCP config #{path}: #{e.message}") if defined?(Clacky::Logger)
            next
          end

          servers = data["mcpServers"] || data["servers"] || {}
          servers.each do |name, spec|
            next unless spec.is_a?(Hash)
            next if spec["disabled"] == true

            type = (spec["type"] || (spec["url"] ? "http" : "stdio")).to_s
            case type
            when "stdio"
              next unless spec["command"]
            when "http", "streamable-http"
              next unless spec["url"]
            else
              next
            end

            @servers[name.to_s] = spec
          end
        end
      end

      private def default_description_for(name)
        "MCP server '#{name}'. Use this skill to delegate any task that this server " \
          "can handle. The subagent will see the server's full tool list at fork time."
      end

      private def start_reaper
        return if @idle_timeout.nil? || @idle_timeout <= 0

        @reaper_thread = Thread.new do
          loop do
            sleep [@idle_timeout / 5, 30].min
            now = Time.now
            @lock.synchronize do
              @clients.each do |name, client|
                next unless client.last_used_at
                if now - client.last_used_at > @idle_timeout
                  client.stop
                  @clients.delete(name)
                end
              end
            end
          end
        rescue StandardError
          # Reaper thread must never crash the main agent. Best-effort.
        end
        @reaper_thread.name = "mcp-reaper" if @reaper_thread.respond_to?(:name=)
      end
    end
  end
end
