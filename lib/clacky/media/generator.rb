# frozen_string_literal: true

require_relative "openai_compat"

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

      private def build_provider_for(entry)
        # Today every supported image backend (OpenAI, OpenRouter, openclacky
        # platform) exposes the same OpenAI-compatible /v1/images/generations
        # endpoint, so one class covers them all. When FAL or another
        # non-compatible backend lands, this is the dispatch point that
        # branches by Providers.find_by_base_url(entry["base_url"]).
        OpenAICompat.new(entry)
      end
    end
  end
end
