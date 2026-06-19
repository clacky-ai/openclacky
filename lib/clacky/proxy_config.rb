# frozen_string_literal: true

module Clacky
  # Centralized HTTP proxy policy for the current process.
  #
  # Single source of truth: AgentConfig#proxy_url. We never honour the user's
  # shell ENV (HTTP_PROXY etc.) — it's stripped on every install! so a stale
  # proxy in the launching shell can't poison Clacky.
  #
  # epoch increments on every actual change so that long-lived consumers
  # (e.g. Faraday connections cached on Client instances) can detect when
  # their cached state is stale and rebuild.
  module ProxyConfig
    PROXY_ENV_KEYS = %w[
      http_proxy HTTP_PROXY
      https_proxy HTTPS_PROXY
      all_proxy ALL_PROXY
    ].freeze

    @installed_signature = nil
    @epoch = 0

    class << self
      attr_reader :epoch

      def install!
        url = load_proxy_url
        sig = url
        return if sig == @installed_signature

        strip_env_proxy
        assign_env_proxy(url) if url && !url.empty?
        ensure_faraday_reads_env

        @installed_signature = sig
        @epoch += 1
      end

      def reset_cache!
        @installed_signature = nil
        install!
      end

      private def assign_env_proxy(url)
        %w[http_proxy HTTP_PROXY https_proxy HTTPS_PROXY].each { |k| ENV[k] = url }
      end

      private def strip_env_proxy
        PROXY_ENV_KEYS.each { |k| ENV.delete(k) }
      end

      private def ensure_faraday_reads_env
        return unless defined?(Faraday)
        Faraday.ignore_env_proxy = false if Faraday.respond_to?(:ignore_env_proxy=)
      end

      private def load_proxy_url
        cfg = Clacky::AgentConfig.load
        cfg.respond_to?(:proxy_url) ? cfg.proxy_url.to_s.strip : ""
      rescue StandardError
        ""
      end
    end
  end
end
