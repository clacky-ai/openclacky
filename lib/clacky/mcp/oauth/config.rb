# frozen_string_literal: true

require "uri"

module Clacky
  module Mcp
    module OAuth
      class Config
        class Error < StandardError; end

        attr_reader :resource

        def self.from_server_spec(spec)
          spec ||= {}
          auth = spec["auth"]
          enabled = auth.is_a?(Hash) && !auth.empty?
          if enabled && auth["type"].to_s != "oauth"
            raise Error, "unsupported MCP authentication type '#{auth['type']}'"
          end

          resource = enabled ? (auth["resource"] || spec["url"]) : spec["url"]
          new(enabled: enabled, resource: resource)
        end

        def initialize(enabled:, resource:)
          @enabled = enabled
          @resource = resource.to_s
          validate! if enabled?
        end

        def enabled?
          @enabled == true
        end

        private def validate!
          uri = URI.parse(@resource)
          unless uri.scheme == "https" && uri.host && !uri.host.empty? && !uri.user && !uri.password
            raise Error, "OAuth MCP resource must be an HTTPS URL without credentials"
          end
        rescue URI::InvalidURIError
          raise Error, "OAuth MCP resource must be an HTTPS URL"
        end
      end
    end
  end
end
