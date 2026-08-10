# frozen_string_literal: true

require "monitor"

module Clacky
  module Mcp
    module OAuth
      class Session
        EXPIRY_SKEW = 60

        class Error < StandardError; end
        class NotConnectedError < Error; end

        def initialize(store:, manager:, clock: nil)
          @store = store
          @manager = manager
          @clock = clock || -> { Time.now.to_i }
          @force_refresh = false
          @lock = Monitor.new
        end

        def authorization_headers
          @lock.synchronize do
            grant = @store.load
            raise NotConnectedError, "OAuth MCP is not connected; run `clacky mcp login SERVER`" unless grant

            if @force_refresh || expiring?(grant)
              grant = @manager.refresh(grant)
              @store.save(grant)
              @force_refresh = false
            end
            token = grant["access_token"].to_s
            raise Error, "stored OAuth grant has no access token; log in again" if token.empty?
            { "Authorization" => "Bearer #{token}" }
          end
        rescue NotConnectedError, Error
          raise
        rescue StandardError => e
          raise Error, "OAuth session failed (#{e.class}); log in again"
        end

        def invalidate!
          @lock.synchronize { @force_refresh = true }
        end

        def login
          @lock.synchronize do
            grant = @manager.login
            @force_refresh = false
            grant
          end
        end

        def logout
          @lock.synchronize do
            @store.delete
            @force_refresh = false
          end
          true
        end

        def connected?
          !@store.load.nil?
        rescue StandardError
          false
        end

        def status
          grant = @store.load
          return { "connected" => false } unless grant
          {
            "connected" => true,
            "expires_at" => grant["expires_at"],
            "expired" => grant.fetch("expires_at", 0).to_i <= @clock.call
          }
        end

        def inspect
          "#<#{self.class} connected=#{connected?}>"
        end

        private def expiring?(grant)
          grant.fetch("expires_at", 0).to_i <= @clock.call + EXPIRY_SKEW
        end
      end
    end
  end
end
