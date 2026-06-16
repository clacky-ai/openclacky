# frozen_string_literal: true

require "fileutils"
require "base64"
require "securerandom"
require "faraday"

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

      # @return [Hash] either video_success_response(...) or
      #   video_error_response(...)
      def generate_video(prompt:, aspect_ratio: "landscape", duration_seconds: nil, output_dir: nil, **_kwargs)
        video_error_response(
          error: "Video generation is not supported by #{self.class.name.split("::").last}. Use the openclacky gateway with a video model such as or-veo-3-1.",
          error_type: "not_implemented",
          provider: "",
          prompt: prompt,
          aspect_ratio: aspect_ratio
        )
      end

      # @return [Hash] either audio_success_response(...) or audio_error_response(...)
      def generate_speech(input:, voice: nil, output_dir: nil, **_kwargs)
        audio_error_response(
          error: "Speech synthesis is not supported by #{self.class.name.split("::").last}. Use the openclacky gateway with a TTS model such as or-tts-gemini-2-5-flash.",
          error_type: "not_implemented",
          provider: "",
          input: input
        )
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

      # Persist a base64-encoded video under <output_dir>/assets/generated/.
      # Returns the absolute path on disk. Mirrors #save_b64_image; the only
      # difference is the default extension (mp4).
      private def save_b64_video(b64_data, output_dir:, prefix: "vid", extension: "mp4")
        target_dir = File.join(output_dir, "assets", "generated")
        FileUtils.mkdir_p(target_dir)
        ts    = Time.now.strftime("%Y%m%d_%H%M%S")
        short = SecureRandom.hex(4)
        path  = File.join(target_dir, "#{prefix}_#{ts}_#{short}.#{extension}")
        File.binwrite(path, Base64.decode64(b64_data))
        path
      end

      private def save_b64_audio(b64_data, output_dir:, prefix: "tts", extension: "wav")
        target_dir = File.join(output_dir, "assets", "generated")
        FileUtils.mkdir_p(target_dir)
        ts    = Time.now.strftime("%Y%m%d_%H%M%S")
        short = SecureRandom.hex(4)
        path  = File.join(target_dir, "#{prefix}_#{ts}_#{short}.#{extension}")
        File.binwrite(path, Base64.decode64(b64_data))
        path
      end

      # Download a remote image URL and persist it under
      # <output_dir>/assets/generated/, mirroring save_b64_image so providers
      # that return URLs (e.g. DashScope, whose links expire after 24h) land
      # local files at the same path shape as base64 providers.
      # Returns the absolute path on disk, or nil if the download fails.
      private def save_image_from_url(url, output_dir:, prefix: "img", extension: "png")
        body = download_url(url)
        return nil if body.nil? || body.empty?

        target_dir = File.join(output_dir, "assets", "generated")
        FileUtils.mkdir_p(target_dir)
        ts    = Time.now.strftime("%Y%m%d_%H%M%S")
        short = SecureRandom.hex(4)
        path  = File.join(target_dir, "#{prefix}_#{ts}_#{short}.#{extension}")
        File.binwrite(path, body)
        path
      end

      # Fetch raw bytes from a URL. Isolated so specs can stub it without a
      # live HTTP call. Returns the response body String, or nil on failure.
      private def download_url(url)
        conn = Faraday.new do |f|
          f.options.timeout      = 120
          f.options.open_timeout = 10
        end
        resp = conn.get(url)
        resp.success? ? resp.body : nil
      rescue Faraday::Error
        nil
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

      private def video_success_response(video:, prompt:, aspect_ratio:, provider:, extra: {})
        {
          "success"      => true,
          "video"        => video,
          "model"        => @model,
          "prompt"       => prompt,
          "aspect_ratio" => aspect_ratio,
          "provider"     => provider
        }.merge(extra)
      end

      private def video_error_response(error:, error_type: "provider_error", provider: "", prompt: "", aspect_ratio: "landscape")
        {
          "success"      => false,
          "video"        => nil,
          "error"        => error,
          "error_type"   => error_type,
          "model"        => @model,
          "prompt"       => prompt,
          "aspect_ratio" => aspect_ratio,
          "provider"     => provider
        }
      end

      private def audio_success_response(audio:, input:, voice:, provider:, extra: {})
        {
          "success"  => true,
          "audio"    => audio,
          "model"    => @model,
          "input"    => input,
          "voice"    => voice,
          "provider" => provider
        }.merge(extra)
      end

      private def audio_error_response(error:, error_type: "provider_error", provider: "", input: "", voice: "")
        {
          "success"    => false,
          "audio"      => nil,
          "error"      => error,
          "error_type" => error_type,
          "model"      => @model,
          "input"      => input,
          "voice"      => voice,
          "provider"   => provider
        }
      end
    end
  end
end
