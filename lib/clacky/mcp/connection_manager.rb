# frozen_string_literal: true

require "json"
require_relative "oauth/config"
require_relative "oauth/credential_store"
require_relative "oauth/authorization_manager"
require_relative "oauth/session"

module Clacky
  module Mcp
    class ConnectionManager
      class Error < StandardError; end

      def initialize(server_name:, home: Dir.home, working_dir: Dir.pwd, session_factory: nil)
        @server_name = server_name.to_s
        @home = File.expand_path(home)
        @working_dir = working_dir && File.expand_path(working_dir)
        @session_factory = session_factory || lambda do |_config, store, manager|
          OAuth::Session.new(store: store, manager: manager)
        end
      end

      def login
        session.login
        safe_status
      rescue OAuth::AuthorizationManager::Error, OAuth::Session::Error, OAuth::CredentialStore::Error => e
        raise Error, e.message
      end

      def status
        safe_status
      rescue OAuth::CredentialStore::Error => e
        raise Error, e.message
      end

      def logout
        session.logout
        { "server" => @server_name, "connected" => false }
      rescue OAuth::Session::Error, OAuth::CredentialStore::Error => e
        raise Error, e.message
      end

      private def safe_status
        session.status.merge("server" => @server_name)
      end

      private def session
        return @session if @session

        spec = server_spec
        raise Error, "MCP server '#{@server_name}' is not configured" unless spec
        config = OAuth::Config.from_server_spec(spec)
        raise Error, "MCP server '#{@server_name}' is not configured for OAuth" unless config.enabled?
        store = OAuth::CredentialStore.new(server_name: @server_name, home: @home)
        manager = OAuth::AuthorizationManager.new(
          server_name: @server_name,
          config: config,
          store: store
        )
        @session = @session_factory.call(config, store, manager)
      rescue OAuth::Config::Error => e
        raise Error, e.message
      end

      private def server_spec
        servers = {}
        config_paths.each do |path|
          next unless File.file?(path)
          document = JSON.parse(File.read(path))
          source = document["mcpServers"] || document["servers"] || {}
          source.each { |name, spec| servers[name.to_s] = spec if spec.is_a?(Hash) }
        rescue JSON::ParserError
          raise Error, "invalid MCP configuration in #{path}"
        end
        servers[@server_name]
      end

      private def config_paths
        paths = [File.join(@home, ".clacky", "mcp.json")]
        paths << File.join(@working_dir, ".clacky", "mcp.json") if @working_dir
        paths
      end
    end
  end
end
