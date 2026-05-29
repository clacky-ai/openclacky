# frozen_string_literal: true

module Clacky
  module Billing
    # Data structure for a single billing record
    # Each API call generates one record with token usage and cost
    BillingRecord = Struct.new(
      :id,                    # Unique record ID (UUID)
      :session_id,            # Associated session ID
      :timestamp,             # Time of the API call
      :model,                 # Model used (e.g., "claude-sonnet-4.5")
      :prompt_tokens,         # Input tokens
      :completion_tokens,     # Output tokens
      :cache_read_tokens,     # Tokens read from cache
      :cache_write_tokens,    # Tokens written to cache
      :cost_usd,              # Cost in USD
      :cost_source,           # Cost source (:api, :price, :estimated)
      keyword_init: true
    ) do
      # Convert to hash for JSON serialization
      def to_h
        {
          id: id,
          session_id: session_id,
          timestamp: timestamp.is_a?(Time) ? timestamp.iso8601 : timestamp,
          model: model,
          prompt_tokens: prompt_tokens || 0,
          completion_tokens: completion_tokens || 0,
          cache_read_tokens: cache_read_tokens || 0,
          cache_write_tokens: cache_write_tokens || 0,
          cost_usd: cost_usd || 0.0,
          cost_source: cost_source&.to_s
        }
      end

      # Create from hash (for deserialization)
      def self.from_h(hash)
        new(
          id: hash[:id] || hash["id"],
          session_id: hash[:session_id] || hash["session_id"],
          timestamp: parse_timestamp(hash[:timestamp] || hash["timestamp"]),
          model: hash[:model] || hash["model"],
          prompt_tokens: hash[:prompt_tokens] || hash["prompt_tokens"] || 0,
          completion_tokens: hash[:completion_tokens] || hash["completion_tokens"] || 0,
          cache_read_tokens: hash[:cache_read_tokens] || hash["cache_read_tokens"] || 0,
          cache_write_tokens: hash[:cache_write_tokens] || hash["cache_write_tokens"] || 0,
          cost_usd: hash[:cost_usd] || hash["cost_usd"] || 0.0,
          cost_source: (hash[:cost_source] || hash["cost_source"])&.to_sym
        )
      end

      # Parse timestamp from string or return as-is if already Time
      def self.parse_timestamp(ts)
        return ts if ts.is_a?(Time)
        return Time.now if ts.nil?
        Time.parse(ts)
      rescue
        Time.now
      end

      # Total tokens (input + output)
      def total_tokens
        (prompt_tokens || 0) + (completion_tokens || 0)
      end
    end
  end
end
