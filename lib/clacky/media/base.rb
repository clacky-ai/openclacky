# frozen_string_literal: true

require "fileutils"
require "base64"
require "securerandom"

module Clacky
  module Media
    # Abstract base for media (image / video / audio) generation providers.
    #
    # Subclasses implement #generate_image (and later #generate_video,
    # #generate_audio). The base class supplies the uniform success/error
    # response shape and the on-disk persistence helper, mirroring the
    # design used by Hermes' image_gen_provider so the surface stays
    # learnable across modalities.
    class Base
      # @param model_entry [Hash] one entry from AgentConfig#models — must
      #   include "model", "base_url", "api_key" keys.
      def initialize(model_entry)
        @model_entry = model_entry
        @model       = model_entry["model"]
        @base_url    = model_entry["base_url"]
        @api_key     = model_entry["api_key"]
      end

      # @return [Hash] either success_response(...) or error_response(...)
      def generate_image(prompt:, aspect_ratio: "landscape", output_dir: nil, **_kwargs)
        raise NotImplementedError, "#{self.class.name} must implement #generate_image"
      end

      # Persist a base64-encoded image under <output_dir>/assets/generated/.
      # Returns the absolute path on disk.
      private def save_b64_image(b64_data, output_dir:, prefix: "img", extension: "png")
        target_dir = File.join(output_dir, "assets", "generated")
        FileUtils.mkdir_p(target_dir)
        ts    = Time.now.strftime("%Y%m%d_%H%M%S")
        short = SecureRandom.hex(4)
        path  = File.join(target_dir, "#{prefix}_#{ts}_#{short}.#{extension}")
        File.binwrite(path, Base64.decode64(b64_data))
        path
      end

      private def success_response(image:, prompt:, aspect_ratio:, provider:, extra: {})
        {
          "success"      => true,
          "image"        => image,
          "model"        => @model,
          "prompt"       => prompt,
          "aspect_ratio" => aspect_ratio,
          "provider"     => provider
        }.merge(extra)
      end

      private def error_response(error:, error_type: "provider_error", provider: "", prompt: "", aspect_ratio: "landscape")
        {
          "success"      => false,
          "image"        => nil,
          "error"        => error,
          "error_type"   => error_type,
          "model"        => @model,
          "prompt"       => prompt,
          "aspect_ratio" => aspect_ratio,
          "provider"     => provider
        }
      end
    end
  end
end
