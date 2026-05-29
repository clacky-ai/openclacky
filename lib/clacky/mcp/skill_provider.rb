# frozen_string_literal: true

require "json"

require_relative "virtual_skill"

module Clacky
  module Mcp
    # Static, read-only provider that translates ~/.clacky/mcp.json (and the
    # project-level override) into VirtualSkill instances for the SkillLoader.
    #
    # Unlike Mcp::Registry, this class never spawns server processes, never
    # talks JSON-RPC, and holds no mutable state. All actual MCP traffic flows
    # through the local Clacky HTTP API (/api/mcp/:server/tools and /call),
    # which subagents reach via curl. This keeps agents process-light and
    # decouples skill discovery from server lifecycle.
    class SkillProvider
      def initialize(working_dir: nil)
        @working_dir = working_dir
      end

      def virtual_skills
        load_servers.map do |name, spec|
          VirtualSkill.new(
            server_name: name,
            description: spec["description"] || default_description_for(name)
          )
        end
      end

      private def load_servers
        servers = {}
        config_paths.each do |path|
          next unless File.exist?(path)

          begin
            data = JSON.parse(File.read(path))
          rescue JSON::ParserError => e
            Clacky::Logger.warn("Skipping malformed MCP config #{path}: #{e.message}") if defined?(Clacky::Logger)
            next
          end

          (data["mcpServers"] || data["servers"] || {}).each do |name, spec|
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

            servers[name.to_s] = spec
          end
        end
        servers
      end

      private def config_paths
        paths = [File.join(Dir.home, ".clacky", "mcp.json")]
        paths << File.join(@working_dir, ".clacky", "mcp.json") if @working_dir
        paths
      end

      private def default_description_for(name)
        "MCP server '#{name}'. Required entry point for any operation against " \
          "this server — invoke this skill so a subagent runs the calls."
      end
    end
  end
end
