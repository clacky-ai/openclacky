# frozen_string_literal: true

require "faraday"
require "json"
require "uri"
require_relative "base"

module Clacky
  module Media
    # Alibaba DashScope (Qwen-Image) image generation provider.
    #
    # DashScope is NOT an OpenAI-compatible image API. It has its own
    # endpoint, request envelope and response schema:
    #
    #   POST <host>/api/v1/services/aigc/multimodal-generation/generation
    #   Authorization: Bearer <key>
    #   { "model": "qwen-image-2.0-pro",
    #     "input":      { "messages": [ { "role": "user",
    #                                     "content": [ { "text": "<prompt>" } ] } ] },
    #     "parameters": { "size": "2048*2048", "n": 1,
    #                     "prompt_extend": true, "watermark": false } }
    #
    #   => { "output": { "choices": [ { "message": { "content": [
    #          { "image": "https://...png?Expires=..." } ] } } ] },
    #        "usage": { "width": 2048, "height": 2048, "image_count": 1 } }
    #
    # The image link expires after 24h, so we download and persist it under
    # <output_dir>/assets/generated/ (via Base#save_image_from_url), matching
    # the on-disk shape of the base64 providers.
    #
    # Routing: Generator sends any base_url under *.aliyuncs.com here. We
    # derive the real generation endpoint from the host so users can paste
    # the compatible-mode base_url (…/compatible-mode/v1) they already use
    # for Qwen text models and still get working image generation.
    class DashScope < Base
      GENERATION_PATH = "/api/v1/services/aigc/multimodal-generation/generation"

      # aspect_ratio -> "<width>*<height>" (DashScope uses '*' not 'x').
      # qwen-image-2.0 / -plus / -max share these recommended resolutions;
      # the 2.0 series accepts arbitrary sizes within 512*512..2048*2048,
      # the max/plus series only accept a fixed set, so we stick to values
      # that are valid for every family.
      ASPECT_TO_SIZE_V2 = {
        "landscape" => "2688*1536", # 16:9
        "square"    => "2048*2048", # 1:1
        "portrait"  => "1536*2688"  # 9:16
      }.freeze

      ASPECT_TO_SIZE_MAX_PLUS = {
        "landscape" => "1664*928",  # 16:9
        "square"    => "1328*1328", # 1:1
        "portrait"  => "928*1664"   # 9:16
      }.freeze

      DEFAULT_ASPECT = "landscape"
      PROVIDER_ID    = "qwen"

      def generate_image(prompt:, aspect_ratio: DEFAULT_ASPECT, output_dir: nil, n: 1, **_kwargs)
        aspect = size_table.key?(aspect_ratio) ? aspect_ratio : DEFAULT_ASPECT
        size   = size_table[aspect]

        if prompt.to_s.strip.empty?
          return error_response(
            error: "Prompt is required and must be a non-empty string",
            error_type: "invalid_argument",
            provider: PROVIDER_ID,
            aspect_ratio: aspect
          )
        end

        if @api_key.to_s.empty?
          return error_response(
            error: "api_key not configured for image model '#{@model}'",
            error_type: "auth_required",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        payload = {
          model: @model,
          input: {
            messages: [
              { role: "user", content: [{ text: prompt }] }
            ]
          },
          parameters: {
            size: size,
            n: n,
            prompt_extend: true,
            watermark: false
          }
        }

        begin
          response = connection.post(GENERATION_PATH) do |req|
            req.headers["Content-Type"]  = "application/json"
            req.headers["Authorization"] = "Bearer #{@api_key}"
            req.body = JSON.generate(payload)
          end
        rescue Faraday::Error => e
          return error_response(
            error: "HTTP request failed: #{e.message}",
            error_type: "network_error",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        body = parse_json(response.body)
        unless body.is_a?(Hash)
          return error_response(
            error: "Invalid JSON response from upstream",
            error_type: "invalid_response",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        # DashScope reports business failures via top-level code/message,
        # sometimes alongside a non-2xx status, sometimes 200.
        if body["code"] && !body["code"].to_s.empty?
          return error_response(
            error: "Upstream error #{body["code"]}: #{body["message"]}",
            error_type: "api_error",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        unless response.success?
          return error_response(
            error: "Upstream #{response.status}: #{truncate(response.body, 500)}",
            error_type: "api_error",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        image_url = extract_image_url(body)
        if image_url.nil?
          return error_response(
            error: "Upstream returned no image data",
            error_type: "empty_response",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        local_path = save_image_from_url(image_url, output_dir: output_dir || Dir.pwd, prefix: "img")
        if local_path.nil?
          return error_response(
            error: "Failed to download generated image from #{image_url}",
            error_type: "download_failed",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect
          )
        end

        usage = body["usage"]
        success_response(
          image: local_path,
          prompt: prompt,
          aspect_ratio: aspect,
          provider: PROVIDER_ID,
          extra: {
            "size"      => size,
            "usage"     => usage,
            "request_id" => body["request_id"]
          }.compact
        )
      end

      # qwen-image-max / qwen-image-plus accept only the fixed resolution set;
      # everything else (qwen-image-2.0 family, plain qwen-image) uses the 2.0
      # recommended sizes.
      private def size_table
        if @model.to_s.match?(/qwen-image-(max|plus)/i)
          ASPECT_TO_SIZE_MAX_PLUS
        else
          ASPECT_TO_SIZE_V2
        end
      end

      # output.choices[].message.content[].image -> first image URL
      private def extract_image_url(body)
        choices = body.dig("output", "choices")
        return nil unless choices.is_a?(Array)

        choices.each do |choice|
          content = choice.dig("message", "content")
          next unless content.is_a?(Array)

          content.each do |block|
            img = block.is_a?(Hash) ? block["image"] : nil
            return img if img.is_a?(String) && !img.empty?
          end
        end
        nil
      end

      private def connection
        Faraday.new(url: endpoint_base) do |f|
          f.options.timeout      = 240
          f.options.open_timeout = 10
        end
      end

      # Derive the API root (scheme + host) from the configured base_url,
      # discarding any path the user pasted (e.g. /compatible-mode/v1). The
      # generation path is then appended by #connection.post. Falls back to
      # the mainland host if the configured URL can't be parsed.
      private def endpoint_base
        uri = URI.parse(@base_url.to_s)
        if uri.scheme && uri.host
          "#{uri.scheme}://#{uri.host}"
        else
          "https://dashscope.aliyuncs.com"
        end
      rescue URI::InvalidURIError
        "https://dashscope.aliyuncs.com"
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
