# frozen_string_literal: true

require "thor"
require "json"
require_relative "connection_manager"

module Clacky
  module Mcp
    class CliCommands < Thor
      desc "capabilities", "Report MCP client capabilities"
      option :json, type: :boolean, default: false
      def capabilities
        result = { "remote_oauth" => true }
        emit(result, "Remote MCP OAuth: supported")
      end

      desc "login SERVER", "Authorize an OAuth-protected remote MCP server"
      option :json, type: :boolean, default: false
      def login(server)
        result = manager(server).login
        emit(result, "Connected MCP server '#{server}'.")
      rescue ConnectionManager::Error => e
        fail_with(e.message)
      end

      desc "status SERVER", "Show remote MCP authorization status"
      option :json, type: :boolean, default: false
      def status(server)
        result = manager(server).status
        label = result["connected"] ? "connected" : "disconnected"
        emit(result, "MCP server '#{server}' is #{label}.")
      rescue ConnectionManager::Error => e
        fail_with(e.message)
      end

      desc "logout SERVER", "Delete credentials for a remote MCP server"
      option :json, type: :boolean, default: false
      def logout(server)
        result = manager(server).logout
        emit(result, "Disconnected MCP server '#{server}'.")
      rescue ConnectionManager::Error => e
        fail_with(e.message)
      end

      no_commands do
        private def manager(server)
          ConnectionManager.new(server_name: server)
        end

        private def emit(result, text)
          puts(options[:json] ? JSON.generate(result) : text)
        end

        private def fail_with(message)
          warn message
          raise Thor::Error, message
        end
      end
    end
  end
end
