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
          new(enabled: enabled, resource: resource, endpoint: spec["url"])
        end

        def initialize(enabled:, resource:, endpoint: nil)
          @enabled = enabled
          @resource = resource.to_s
          @endpoint = (endpoint || resource).to_s
          validate! if enabled?
        end

        def enabled?
          @enabled == true
        end

        private def validate!
          validate_https_url(@endpoint, "OAuth MCP endpoint")
          validate_https_url(@resource, "OAuth MCP resource")
        end

        private def validate_https_url(value, label)
          uri = URI.parse(value)
          raise Error, "#{label} must be an HTTPS URL without credentials" unless
            uri.scheme == "https" && uri.host && !uri.host.empty? && !uri.user && !uri.password
        rescue URI::InvalidURIError
          raise Error, "#{label} must be an HTTPS URL"
        end
      end
    end
  end
end
