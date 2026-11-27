# frozen_string_literal: true

module Clacky
  module Billing
    # Media calls (image / video / TTS / STT) are billed per request rather than
    # per agent turn, and every caller needs the same log line plus ledger row.
    # Kept in one place so a new media path cannot silently skip billing the way
    # meeting transcription did.
    module MediaUsage
      module_function

      # @param result [Hash] media generator result (contains "usage" / "cost_usd")
      # @param kind [String, nil] "image" / "video" / "audio" / "stt"; inferred when nil
      def record(result, prompt: nil, session_id: nil, kind: nil)
        return unless result.is_a?(Hash)

        usage = result["usage"]
        cost  = result["cost_usd"]
        return if usage.nil? && cost.nil?

        kind ||= infer_kind(result)
        log(result, usage, cost, prompt, kind)
        append(result, usage, cost, session_id)
      end

      def infer_kind(result)
        return "video" if result.key?("video")
        return "audio" if result.key?("audio")
        return "stt" if result.key?("text")

        "image"
      end

      def log(result, usage, cost, prompt, kind)
        parts = []
        parts << "model=#{result["model"]}"
        parts << "provider=#{result["provider"]}"
        if usage.is_a?(Hash)
          parts << "prompt_tokens=#{usage["prompt_tokens"]}" unless usage["prompt_tokens"].nil?
          parts << "completion_tokens=#{usage["completion_tokens"]}" unless usage["completion_tokens"].nil?
          parts << "cache_read=#{usage["cache_read_tokens"]}" if usage["cache_read_tokens"].to_i > 0
          parts << "cache_write=#{usage["cache_write_tokens"]}" if usage["cache_write_tokens"].to_i > 0
          parts << format("audio_seconds=%.2f", usage["audio_seconds"].to_f) unless usage["audio_seconds"].nil?
        end
        parts << format("cost_usd=%.6f", cost.to_f) unless cost.nil?
        parts << "prompt=#{prompt[0, 60].inspect}" if prompt
        Clacky::Logger.info("[Media] #{kind} generated #{parts.join(" ")}")
      end

      def append(result, usage, cost, session_id)
        require_relative "billing_store"
        require_relative "billing_record"

        record = Clacky::Billing::BillingRecord.new(
          session_id:         session_id,
          model:              result["model"].to_s,
          provider:           result["provider"].to_s,
          prompt_tokens:      usage.is_a?(Hash) ? usage["prompt_tokens"].to_i : 0,
          completion_tokens:  usage.is_a?(Hash) ? usage["completion_tokens"].to_i : 0,
          cache_read_tokens:  usage.is_a?(Hash) ? usage["cache_read_tokens"].to_i : 0,
          cache_write_tokens: usage.is_a?(Hash) ? usage["cache_write_tokens"].to_i : 0,
          cost_usd:           cost.to_f,
          cost_source:        (result["cost_source"] || "api").to_sym
        )
        Clacky::Billing::BillingStore.new.append(record)
      end
    end
  end
end
