# frozen_string_literal: true

require "faraday"
require "json"
require_relative "base"

module Clacky
  module Media
    # OpenAI-compatible image generation provider.
    #
    # Talks to POST <base_url>/images/generations with the standard OpenAI
    # request shape. Handles three providers under one class because they
    # all expose the same endpoint: OpenAI, OpenRouter, and the openclacky
    # platform gateway. Provider-specific quirks (model id naming, billing)
    # live in PRESETS, not here.
    class OpenAICompat < Base
      ASPECT_TO_SIZE = {
        "landscape" => "1536x1024",
        "square"    => "1024x1024",
        "portrait"  => "1024x1536"
      }.freeze

      DEFAULT_ASPECT = "landscape"

      def generate_image(prompt:, aspect_ratio: DEFAULT_ASPECT, output_dir: nil, n: 1, **_kwargs)
        provider_id = Clacky::Providers.find_by_base_url(@base_url) || "custom"
        aspect      = ASPECT_TO_SIZE.key?(aspect_ratio) ? aspect_ratio : DEFAULT_ASPECT
        size        = ASPECT_TO_SIZE[aspect]

        if prompt.to_s.strip.empty?
          return error_response(
            error: "Prompt is required and must be a non-empty string",
            error_type: "invalid_argument",
            provider: provider_id,
            aspect_ratio: aspect
          )
        end

        if @api_key.to_s.empty?
          return error_response(
            error: "api_key not configured for image model '#{@model}'",
            error_type: "auth_required",
            provider: provider_id,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        payload = { model: @model, n: n }
        if gemini_family?(@model)
          # Gemini image models (routed via openclacky / openrouter gateway)
          # don't accept the OpenAI `size` parameter — they infer aspect from
          # the prompt text. Embedding a hint keeps the user's aspect choice
          # honoured without breaking the gateway request validator.
          payload[:prompt] = "#{prompt}\n\n[aspect: #{aspect}]"
        else
          payload[:prompt] = prompt
          payload[:size]   = size
        end

        begin
          response = connection.post("images/generations") do |req|
            req.headers["Content-Type"]  = "application/json"
            req.headers["Authorization"] = "Bearer #{@api_key}"
            req.body = JSON.generate(payload)
          end
        rescue Faraday::Error => e
          return error_response(
            error: "HTTP request failed: #{e.message}",
            error_type: "network_error",
            provider: provider_id,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        unless response.success?
          return error_response(
            error: "Upstream #{response.status}: #{truncate(response.body, 500)}",
            error_type: "api_error",
            provider: provider_id,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        body = parse_json(response.body)
        return error_response(
          error: "Invalid JSON response from upstream",
          error_type: "invalid_response",
          provider: provider_id,
          prompt: prompt,
          aspect_ratio: aspect
        ) unless body.is_a?(Hash)

        data = body["data"] || []
        first = data.first
        if first.nil?
          return error_response(
            error: "Upstream returned no image data",
            error_type: "empty_response",
            provider: provider_id,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        image_ref =
          if first["b64_json"]
            save_b64_image(first["b64_json"], output_dir: output_dir || Dir.pwd, prefix: "img")
          elsif first["url"]
            first["url"]
          end

        if image_ref.nil?
          return error_response(
            error: "Response contained neither b64_json nor url",
            error_type: "empty_response",
            provider: provider_id,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        success_response(
          image: image_ref,
          prompt: prompt,
          aspect_ratio: aspect,
          provider: provider_id,
          extra: {
            "size"     => size,
            "usage"    => body["usage"],
            "cost_usd" => body["cost_usd"]
          }.compact
        )
      end

      private def connection
        Faraday.new(url: normalized_base_url) do |f|
          f.options.timeout      = 240
          f.options.open_timeout = 10
        end
      end

      private def gemini_family?(model_name)
        model_name.to_s.match?(/gemini|imagen/i)
      end

      # base_url is taken verbatim from PRESETS (each provider already
      # includes the API version segment when needed). We only ensure a
      # trailing slash so Faraday's relative-path join behaves.
      private def normalized_base_url
        "#{@base_url.to_s.chomp("/")}/"
      end

      private def parse_json(body)
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      private def truncate(str, max)
        s = str.to_s
        s.length > max ? "#{s[0, max]}..." : s
      end
    end
  end
end
