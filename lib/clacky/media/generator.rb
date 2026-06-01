# frozen_string_literal: true

require_relative "openai_compat"
require_relative "gemini"

module Clacky
  module Media
    # Top-level dispatcher: takes an AgentConfig and a request, picks the
    # right provider class based on the configured image model's base_url,
    # and delegates.
    #
    # Adding a new modality (video / audio) means:
    #   1. add a generate_<modality> method here that resolves the correct
    #      type=<modality> entry and class
    #   2. add a provider class under lib/clacky/media/ implementing the call
    class Generator
      # Hosts that speak the native Google AI Studio API instead of an
      # OpenAI-compatible facade. Matched as a substring against the
      # configured base_url so any regional / staging variant is caught.
      GOOGLE_NATIVE_HOSTS = [
        "generativelanguage.googleapis.com",
        "aiplatform.googleapis.com"
      ].freeze

      # @param agent_config [Clacky::AgentConfig]
      def initialize(agent_config)
        @agent_config = agent_config
      end

      # @return [Hash, nil] the type=image model entry, or nil if not configured
      def image_model_entry
        @agent_config.find_model_by_type("image")
      end

      def generate_image(prompt:, aspect_ratio: "landscape", output_dir: nil, **kwargs)
        entry = image_model_entry
        if entry.nil?
          return {
            "success"    => false,
            "image"      => nil,
            "error"      => "No image model configured. Add a model with type=image in settings.",
            "error_type" => "not_configured",
            "provider"   => "",
            "model"      => "",
            "prompt"     => prompt
          }
        end

        provider = build_provider_for(entry)
        provider.generate_image(
          prompt: prompt,
          aspect_ratio: aspect_ratio,
          output_dir: output_dir,
          **kwargs
        )
      end

      # Pick the adapter class for a media model entry.
      #
      # Routing rules:
      #   • base_url points directly at a Google AI Studio host → Gemini
      #     (native /v1beta/models/<m>:generateContent schema).
      #   • everything else → OpenAICompat. This covers OpenAI itself, the
      #     openclacky gateway, OpenRouter, and any third-party proxy that
      #     re-exposes Gemini / Imagen / DALL-E behind /v1/images/generations.
      #     OpenAICompat#generate_image branches internally on model id to
      #     drop OpenAI-only params (size) when talking to Gemini families.
      private def build_provider_for(entry)
        url = entry["base_url"].to_s
        if GOOGLE_NATIVE_HOSTS.any? { |host| url.include?(host) }
          Gemini.new(entry)
        else
          OpenAICompat.new(entry)
        end
      end
    end
  end
end
