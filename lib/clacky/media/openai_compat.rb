# frozen_string_literal: true

require "faraday"
require "json"
require "base64"
require "securerandom"
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

      # Video aspect ratios accepted by the gateway's /videos/generations
      # endpoint. The human-friendly labels map straight through; the gateway
      # normalises to Veo's "16:9" / "9:16" internally.
      VIDEO_ASPECTS = %w[landscape portrait].freeze
      DEFAULT_VIDEO_DURATION = 8

      def generate_image(prompt:, aspect_ratio: DEFAULT_ASPECT, output_dir: nil, n: 1, image: nil, images: nil, **_kwargs)
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

        begin
          input_images = normalize_input_images(image, images)
        rescue ArgumentError => e
          return error_response(
            error: e.message,
            error_type: "invalid_argument",
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

        # With input image(s) this becomes an edit: the gateway forwards them
        # to the model alongside the prompt. Sent as `images` (array) so
        # multi-image edits work; the gateway also accepts a single `image`.
        payload[:images] = input_images unless input_images.empty?

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

      def generate_video(prompt:, aspect_ratio: DEFAULT_ASPECT, duration_seconds: nil, output_dir: nil, image: nil, **_kwargs)
        provider_id = Clacky::Providers.find_by_base_url(@base_url) || "custom"
        aspect      = VIDEO_ASPECTS.include?(aspect_ratio) ? aspect_ratio : DEFAULT_ASPECT
        duration    = duration_seconds.to_i
        duration    = DEFAULT_VIDEO_DURATION if duration <= 0

        if prompt.to_s.strip.empty?
          return video_error_response(
            error: "Prompt is required and must be a non-empty string",
            error_type: "invalid_argument", provider: provider_id, aspect_ratio: aspect
          )
        end
        if @api_key.to_s.empty?
          return video_error_response(
            error: "api_key not configured for video model '#{@model}'",
            error_type: "auth_required", provider: provider_id, prompt: prompt, aspect_ratio: aspect
          )
        end

        payload = { model: @model, prompt: prompt, aspect_ratio: aspect, duration_seconds: duration }
        payload[:image] = image if image.is_a?(Hash) && image["b64_json"]

        begin
          response = video_connection.post("videos/generations") do |req|
            req.headers["Content-Type"]  = "application/json"
            req.headers["Authorization"] = "Bearer #{@api_key}"
            req.body = JSON.generate(payload)
          end
        rescue Faraday::Error => e
          return video_error_response(
            error: "HTTP request failed: #{e.message}",
            error_type: "network_error", provider: provider_id, prompt: prompt, aspect_ratio: aspect
          )
        end

        unless response.success?
          return video_error_response(
            error: "Upstream #{response.status}: #{truncate(response.body, 500)}",
            error_type: "api_error", provider: provider_id, prompt: prompt, aspect_ratio: aspect
          )
        end

        body = parse_json(response.body)
        return video_error_response(
          error: "Invalid JSON response from upstream",
          error_type: "invalid_response", provider: provider_id, prompt: prompt, aspect_ratio: aspect
        ) unless body.is_a?(Hash)

        first = (body["data"] || []).first
        if first.nil? || first["b64_json"].to_s.empty?
          return video_error_response(
            error: "Upstream returned no video data",
            error_type: "empty_response", provider: provider_id, prompt: prompt, aspect_ratio: aspect
          )
        end

        path = save_b64_video(first["b64_json"], output_dir: output_dir || Dir.pwd, prefix: "vid")
        video_success_response(
          video: path, prompt: prompt, aspect_ratio: aspect, provider: provider_id,
          extra: {
            "duration_seconds" => duration,
            "usage"            => body["usage"],
            "cost_usd"         => body["cost_usd"]
          }.compact
        )
      end

      def generate_speech(input:, voice: nil, output_dir: nil, **_kwargs)
        provider_id = Clacky::Providers.find_by_base_url(@base_url) || "custom"

        if input.to_s.strip.empty?
          return audio_error_response(
            error: "input is required and must be a non-empty string",
            error_type: "invalid_argument", provider: provider_id, voice: voice.to_s
          )
        end
        if @api_key.to_s.empty?
          return audio_error_response(
            error: "api_key not configured for audio model '#{@model}'",
            error_type: "auth_required", provider: provider_id, input: input, voice: voice.to_s
          )
        end

        payload = { model: @model, input: input }
        payload[:voice] = voice if voice && !voice.to_s.strip.empty?

        begin
          response = audio_connection.post("audio/speech") do |req|
            req.headers["Content-Type"]  = "application/json"
            req.headers["Authorization"] = "Bearer #{@api_key}"
            req.body = JSON.generate(payload)
          end
        rescue Faraday::Error => e
          return audio_error_response(
            error: "HTTP request failed: #{e.message}",
            error_type: "network_error", provider: provider_id, input: input, voice: voice.to_s
          )
        end

        unless response.success?
          return audio_error_response(
            error: "Upstream #{response.status}: #{truncate(response.body, 500)}",
            error_type: "api_error", provider: provider_id, input: input, voice: voice.to_s
          )
        end

        body = parse_json(response.body)
        return audio_error_response(
          error: "Invalid JSON response from upstream",
          error_type: "invalid_response", provider: provider_id, input: input, voice: voice.to_s
        ) unless body.is_a?(Hash)

        first = (body["data"] || []).first
        if first.nil? || first["b64_json"].to_s.empty?
          return audio_error_response(
            error: "Upstream returned no audio data",
            error_type: "empty_response", provider: provider_id, input: input, voice: voice.to_s
          )
        end

        ext = case first["mime_type"].to_s
              when "audio/mpeg", "audio/mp3" then "mp3"
              when "audio/ogg" then "ogg"
              else "wav"
              end

        path = save_b64_audio(first["b64_json"], output_dir: output_dir || Dir.pwd, prefix: "tts", extension: ext)
        audio_success_response(
          audio: path, input: input, voice: body["voice"] || voice.to_s, provider: provider_id,
          extra: {
            "mime_type" => first["mime_type"],
            "usage"     => body["usage"],
            "cost_usd"  => body["cost_usd"]
          }.compact
        )
      end

      def generate_transcription(audio_base64:, mime_type:, prompt: nil, **_kwargs)
        provider_id = Clacky::Providers.find_by_base_url(@base_url) || "custom"

        if @api_key.to_s.empty?
          return transcription_error_response(
            error: "api_key not configured for STT model '#{@model}'",
            error_type: "auth_required", provider: provider_id
          )
        end

        ext = mime_type.split(";").first.split("/").last.then { |e| e == "mpeg" ? "mp3" : e }
        ext = "m4a" if ext == "mp4" # OpenRouter wants the audio format, not the container

        # OpenRouter caps multipart uploads at 25 MB and redirects larger files
        # to base64 JSON via input_audio. The openclacky gateway (which proxies
        # third-party STT like Groq) has its own JSON flavor with the same
        # input_audio shape. Both get the JSON path; plain OpenAI-compatible
        # providers keep multipart.
        if openrouter_host? || openclacky_gateway?
          payload = {
            model: @model,
            input_audio: {
              data:   audio_base64, # raw base64 bytes, NOT a data URI
              format: ext
            }
          }
          payload[:prompt] = prompt.to_s.strip unless prompt.to_s.strip.empty?

          begin
            response = stt_json_connection.post("audio/transcriptions") do |req|
              req.headers["Content-Type"]  = "application/json"
              req.headers["Authorization"] = "Bearer #{@api_key}"
              req.body = JSON.generate(payload)
            end
          rescue Faraday::Error => e
            return transcription_error_response(
              error: "HTTP request failed: #{e.message}",
              error_type: "network_error", provider: provider_id
            )
          end
        else
          filename = "chunk.#{ext}"
          audio_data = Base64.decode64(audio_base64)
          boundary = "----FormBoundary#{SecureRandom.hex(8)}"
          # A multipart body is a byte stream: build it in binary so UTF-8 text
          # parts (e.g. a non-ASCII vocabulary prompt) don't clash with the
          # ASCII-8BIT audio bytes.
          body = "".b
          body << "--#{boundary}\r\n".b
          body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n".b
          body << "Content-Type: #{mime_type.split(';').first}\r\n\r\n".b
          body << audio_data.b
          body << "\r\n--#{boundary}\r\n".b
          body << "Content-Disposition: form-data; name=\"model\"\r\n\r\n".b
          body << @model.to_s.b
          unless prompt.to_s.strip.empty?
            body << "\r\n--#{boundary}\r\n".b
            body << "Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".b
            body << prompt.to_s.strip.b
          end
          body << "\r\n--#{boundary}--\r\n".b

          begin
            response = stt_connection.post("audio/transcriptions") do |req|
              req.headers["Content-Type"]  = "multipart/form-data; boundary=#{boundary}"
              req.headers["Authorization"] = "Bearer #{@api_key}"
              req.body = body
            end
          rescue Faraday::Error => e
            return transcription_error_response(
              error: "HTTP request failed: #{e.message}",
              error_type: "network_error", provider: provider_id
            )
          end
        end

        unless response.success?
          return transcription_error_response(
            error: "Upstream #{response.status}: #{truncate(response.body, 500)}",
            error_type: "api_error", provider: provider_id
          )
        end

        parsed = parse_json(response.body)
        unless parsed.is_a?(Hash)
          return transcription_error_response(
            error: "Invalid JSON response from upstream",
            error_type: "invalid_response", provider: provider_id
          )
        end

        transcription_success_response(
          text: parsed["text"].to_s.strip,
          provider: provider_id,
          extra: {
            "usage"    => parsed["usage"],
            "cost_usd" => parsed["cost_usd"]
          }.compact
        )
      end

      def understand_video(video_base64:, mime_type:, prompt: nil, **_kwargs)
        provider_id = Clacky::Providers.find_by_base_url(@base_url) || "custom"
        prompt = "Describe what you see in this frame." if prompt.to_s.strip.empty?

        if @api_key.to_s.empty?
          return video_understanding_error_response(
            error: "api_key not configured for video understanding model '#{@model}'",
            error_type: "auth_required", provider: provider_id, prompt: prompt
          )
        end

        data_url = "data:#{mime_type};base64,#{video_base64}"

        payload = {
          model: @model,
          messages: [
            {
              role: "user",
              content: [
                { type: "text", text: prompt },
                { type: "image_url", image_url: { url: data_url } }
              ]
            }
          ]
        }

        begin
          response = vu_connection.post("chat/completions") do |req|
            req.headers["Content-Type"]  = "application/json"
            req.headers["Authorization"] = "Bearer #{@api_key}"
            req.body = JSON.generate(payload)
          end
        rescue Faraday::Error => e
          return video_understanding_error_response(
            error: "HTTP request failed: #{e.message}",
            error_type: "network_error", provider: provider_id, prompt: prompt
          )
        end

        unless response.success?
          return video_understanding_error_response(
            error: "Upstream #{response.status}: #{truncate(response.body, 500)}",
            error_type: "api_error", provider: provider_id, prompt: prompt
          )
        end

        parsed = parse_json(response.body)
        unless parsed.is_a?(Hash)
          return video_understanding_error_response(
            error: "Invalid JSON response from upstream",
            error_type: "invalid_response", provider: provider_id, prompt: prompt
          )
        end

        choices = parsed["choices"]
        if choices.nil? || choices.empty?
          return video_understanding_error_response(
            error: "Upstream returned no content",
            error_type: "empty_response", provider: provider_id, prompt: prompt
          )
        end

        text = choices.first.dig("message", "content").to_s.strip
        if text.empty?
          return video_understanding_error_response(
            error: "Upstream returned empty analysis",
            error_type: "empty_response", provider: provider_id, prompt: prompt
          )
        end

        video_understanding_success_response(
          analysis: text,
          prompt: prompt,
          provider: provider_id,
          extra: {
            "usage"    => parsed["usage"],
            "cost_usd" => parsed["cost_usd"]
          }.compact
        )
      end

      private def connection
        Faraday.new(url: normalized_base_url) do |f|
          f.options.timeout      = 240
          f.options.open_timeout = 10
        end
      end

      # Video generation runs the gateway's submit+poll cycle inside one
      # request, which can take several minutes; give it a much longer read
      # timeout than the image path.
      private def video_connection
        Faraday.new(url: normalized_base_url) do |f|
          f.options.timeout      = 600
          f.options.open_timeout = 10
        end
      end

      private def audio_connection
        Faraday.new(url: normalized_base_url) do |f|
          f.options.timeout      = 120
          f.options.open_timeout = 10
        end
      end

      private def stt_connection
        Faraday.new(url: normalized_base_url) do |f|
          f.options.timeout      = 30
          f.options.open_timeout = 10
        end
      end

      # STT JSON body carries a large base64 payload; upstream may need longer
      # to decode/transcribe it than the 30s multipart path.
      private def stt_json_connection
        Faraday.new(url: normalized_base_url) do |f|
          f.options.timeout      = 120
          f.options.open_timeout = 10
        end
      end

      private def openrouter_host?
        @base_url.to_s.include?("openrouter.ai")
      end

      private def openclacky_gateway?
        @base_url.to_s.include?("openclacky.com")
      end

      private def vu_connection
        Faraday.new(url: normalized_base_url) do |f|
          f.options.timeout      = 60
          f.options.open_timeout = 10
        end
      end

      private def gemini_family?(model_name)
        model_name.to_s.match?(/gemini|imagen/i)
      end

      # Normalise the optional image/edit inputs into an array of data URLs
      # ("data:<mime>;base64,<payload>") the gateway understands. Each input
      # may be a local file path, a data URL, or a bare base64 string.
      # `images` (array or single) takes precedence over `image`.
      # Raises ArgumentError on a missing file or undecodable input.
      private def normalize_input_images(image, images)
        raw = images.nil? ? image : images
        return [] if raw.nil?

        list = raw.is_a?(Array) ? raw : [raw]
        list.filter_map do |item|
          s = item.to_s.strip
          next if s.empty?
          to_data_url(s)
        end
      end

      private def to_data_url(input)
        return input if input.start_with?("data:")

        # A filesystem path → read and encode.
        if File.file?(input)
          bytes = File.binread(input)
          mime  = mime_for_path(input)
          return "data:#{mime};base64,#{Base64.strict_encode64(bytes)}"
        end

        # Otherwise treat as a bare base64 payload; validate it decodes.
        begin
          Base64.strict_decode64(input)
        rescue ArgumentError
          raise ArgumentError, "input image is neither an existing file path nor valid base64"
        end
        "data:image/png;base64,#{input}"
      end

      private def mime_for_path(path)
        case File.extname(path).downcase
        when ".jpg", ".jpeg" then "image/jpeg"
        when ".webp"         then "image/webp"
        when ".gif"          then "image/gif"
        else                      "image/png"
        end
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
