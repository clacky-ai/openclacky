# frozen_string_literal: true

require "faraday"
require "json"
require_relative "base"

module Clacky
  module Media
    # Native Google Gemini image generation adapter.
    #
    # Reserved for users who configure a direct Google AI Studio base_url
    # (e.g. https://generativelanguage.googleapis.com) with a raw Google API
    # key. The official endpoints are:
    #   POST /v1beta/models/<model>:generateContent  — image-out via Gemini
    #   POST /v1beta/models/<model>:predict          — Imagen
    # with x-goog-api-key auth, contents[].parts[] request schema, and
    # candidates[].content.parts[].inlineData response schema. Completely
    # different from the OpenAI /v1/images/generations contract.
    #
    # Today every shipping path (openclacky gateway, OpenRouter) wraps Gemini
    # behind an OpenAI-compatible facade, so OpenAICompat handles them and
    # this class is intentionally a stub. We surface a clear error rather
    # than silently 404 against Google's actual host.
    class Gemini < Base
      def generate_image(prompt:, aspect_ratio: "landscape", output_dir: nil, **_kwargs)
        error_response(
          error: "Direct Google AI Studio (generativelanguage.googleapis.com) image generation is not yet supported. Use the openclacky or OpenRouter gateway instead — set base_url to https://api.openclacky.com or https://openrouter.ai/api/v1 and pick a Gemini image model (e.g. or-gemini-3-pro-image, google/gemini-3-pro-image-preview).",
          error_type: "not_implemented",
          provider: "gemini-direct",
          prompt: prompt,
          aspect_ratio: aspect_ratio
        )
      end
    end
  end
end
