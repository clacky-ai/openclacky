# frozen_string_literal: true

require "uri"
require_relative "../platform_http_client"

module Clacky
  module Billing
    # Authoritative usage data from the OpenClacky platform.
    #
    # The gateway records usage against real upstream model ids, while the
    # client persists the user-facing alias (e.g. "dsk-deepseek-v4-pro" is
    # stored as "deepseek-v4-pro" upstream). These tables bridge the two so
    # the billing UI can merge platform data with local data under one name.
    module PlatformBilling
      # alias → real upstream model id, used to translate the model filter
      # before querying the platform API. Vertex ids are preferred as the
      # "primary" id where the gateway can dispatch an alias two ways.
      ALIAS_TO_REAL = {
        # deepseek (dsk-)
        "dsk-deepseek-v4-pro"              => "deepseek-v4-pro",
        "dsk-deepseek-v4-flash"            => "deepseek-v4-flash",
        "dsk-deepseek-v4-flash-vision-exp" => "deepseek-v4-flash-vision-exp",
        # claude via bedrock (abs-)
        "abs-claude-fable-5-1"  => "global.anthropic.claude-fable-5-1",
        "abs-claude-fable-5"    => "global.anthropic.claude-fable-5",
        "abs-claude-opus-5"     => "global.anthropic.claude-opus-5",
        "abs-claude-opus-4-8"   => "global.anthropic.claude-opus-4-8",
        "abs-claude-opus-4-7"   => "global.anthropic.claude-opus-4-7",
        "abs-claude-opus-4-6"   => "global.anthropic.claude-opus-4-6",
        "abs-claude-sonnet-5"   => "global.anthropic.claude-sonnet-5",
        "abs-claude-sonnet-4-6" => "global.anthropic.claude-sonnet-4-6",
        "abs-claude-sonnet-4-5" => "global.anthropic.claude-sonnet-4-5",
        "abs-claude-haiku-4-5"  => "global.anthropic.claude-haiku-4-5",
        # gemini chat (or-)
        "or-gemini-3-1-pro"  => "gemini-3.1-pro-preview",
        "or-gemini-3-7-flash" => "gemini-3.7-flash",
        "or-gemini-3-6-flash" => "gemini-3.6-flash",
        "or-gemini-3-5-flash" => "gemini-3.5-flash",
        # image generation (or-)
        "or-gemini-3-pro-image"     => "gemini-3-pro-image",
        "or-gemini-3-1-flash-image" => "gemini-3.1-flash-image",
        "or-gpt-image-2"            => "openai/gpt-5.4-image-2",
        # video generation (or-)
        "or-veo-3"       => "veo-3.0-generate-001",
        "or-veo-3-fast"  => "veo-3.0-fast-generate-001",
        "or-veo-3-1"     => "veo-3.1-generate-001",
        "or-veo-3-1-fast" => "veo-3.1-fast-generate-001",
        # text-to-speech (or-)
        "or-tts-gemini-2-5-flash" => "gemini-2.5-flash-tts",
        "or-tts-gemini-2-5-pro"   => "gemini-2.5-pro-tts",
        # speech-to-text (or-)
        "or-stt-gemini-3-7-flash" => "gemini-3.7-flash",
        "or-stt-gemini-3-6-flash" => "gemini-3.6-flash",
        "or-stt-gemini-3-5-flash" => "gemini-3.5-flash",
        "or-stt-gemini-1-5-pro"   => "gemini-1.5-pro-002"
      }.freeze

      # real upstream model id → alias, for display. Includes the OpenRouter
      # fallback ids (google/…-preview) the gateway records when Vertex is
      # disabled, in addition to the primary Vertex ids in ALIAS_TO_REAL.
      REAL_TO_ALIAS = ALIAS_TO_REAL.invert.merge(
        "google/gemini-3.1-pro-preview"      => "or-gemini-3-1-pro",
        "google/gemini-3-pro-image-preview"  => "or-gemini-3-pro-image",
        # STT aliases reuse the chat real id; Hash#invert keeps the later STT
        # key, so pin these back to the chat alias for display.
        "gemini-3.7-flash" => "or-gemini-3-7-flash",
        "gemini-3.6-flash" => "or-gemini-3-6-flash",
        "gemini-3.5-flash" => "or-gemini-3-5-flash"
      ).freeze

      class << self
        # Translate a real upstream model id back to the user-facing alias.
        # Unknown ids pass through unchanged (other providers' local records).
        def display_model(real_id)
          REAL_TO_ALIAS.fetch(real_id, real_id)
        end

        # Translate a user-facing alias to the primary real upstream model id.
        # Returns nil when the alias is not an openclacky model.
        def real_model(alias_name)
          ALIAS_TO_REAL[alias_name]
        end

        # Fetch authoritative usage summary for the platform (openclacky).
        # Returns a hash shaped like BillingStore#summary, or nil on failure.
        def fetch_summary(api_key, period:, model: nil)
          path = "/api/v1/usage/summary?period=#{period}"
          path += "&model=#{URI.encode_www_form_component(model)}" if model && !model.empty?

          data = request(api_key, path)
          data && normalize_summary(data)
        end

        # Fetch authoritative daily breakdown for the platform (openclacky).
        # Returns { days: [...] } or nil on failure.
        def fetch_daily(api_key, days:, model: nil)
          path = "/api/v1/usage/daily?days=#{days}"
          path += "&model=#{URI.encode_www_form_component(model)}" if model && !model.empty?

          data = request(api_key, path)
          return nil unless data.is_a?(Hash)

          days_data = data["days"] || data[:days] || []
          days_data = days_data.map do |d|
            next d unless d.is_a?(Hash)

            align_prompt_tokens(d.transform_keys(&:to_sym))
          end
          { days: days_data }
        end

        private def request(api_key, path)
          client = Clacky::PlatformHttpClient.new
          result = client.get(path, headers: { "Authorization" => "Bearer #{api_key}" })
          result[:success] ? result[:data] : nil
        rescue StandardError
          nil
        end

        # Normalise the platform summary (string keys) to the same shape as
        # BillingStore#summary (symbol keys, symbol-keyed by_model entries).
        private def normalize_summary(data)
          return nil unless data.is_a?(Hash)

          normalized = data.transform_keys(&:to_sym)
          if normalized[:by_model].is_a?(Hash)
            normalized[:by_model] = normalized[:by_model].transform_values do |entry|
              entry.is_a?(Hash) ? entry.transform_keys(&:to_sym) : entry
            end
          end
          align_prompt_tokens(normalized)
          normalized
        end

        # The platform reports prompt_tokens as Anthropic's input_tokens (the
        # post-cache tail), while local records store prompt_tokens with
        # cache_read already folded in. Fold cache_read back so prompt/total
        # line up and the UI's `prompt - cache_read` never goes negative.
        private def align_prompt_tokens(entry)
          cache_read = entry[:cache_read_tokens].to_i
          entry[:prompt_tokens] = entry[:prompt_tokens].to_i + cache_read
          entry[:total_tokens] = entry[:total_tokens].to_i + cache_read if entry.key?(:total_tokens)
          entry[:tokens] = entry[:tokens].to_i + cache_read if entry.key?(:tokens)
          entry
        end
      end
    end
  end
end
