# frozen_string_literal: true

require "faraday"
require "json"
require "uri"
require_relative "base"

module Clacky
  module Media
    # Alibaba DashScope (Qwen-Image / CosyVoice / HappyHorse) media generation provider.
    #
    # DashScope is NOT an OpenAI-compatible API. It has its own endpoint,
    # request envelope and response schema for image, speech (TTS), and video generation.
    #
    # Routing: Generator sends any base_url under *.aliyuncs.com here. We
    # derive the real generation endpoint from the host so users can paste
    # the compatible-mode base_url (…/compatible-mode/v1) they already use
    # for Qwen text models and still get working media generation.
    #
    # --- Endpoint migration TODO (2026-06) ---------------------------------
    # Aliyun is gradually deprecating the shared `dashscope.aliyuncs.com`
    # host in favor of the per-workspace MaaS domain
    # `https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com` (intl:
    # `{WorkspaceId}.dashscope-intl.aliyuncs.com`). Docs have already moved
    # to the new domain; the old host still works for most models but is
    # expected to be sunset eventually.
    #
    # Current stance: keep accepting the old shared host as the default
    # (zero-config for users + compatibility with third-party aggregators
    # that don't use aliyuncs.com at all). The new MaaS domain already
    # works today via endpoint_base derivation. Non-real-time TTS
    # (qwen3-tts) does NOT work on the shared host and already emits a
    # hint pointing users at the MaaS domain — see the "url error" branch
    # in generate_speech.
    #
    # Action when Aliyun announces the sunset of compatible-mode:
    #   1. Flip the default expectation to the WorkspaceId MaaS domain.
    #   2. Add a setup flow / docs explaining how to find WorkspaceId.
    #   3. Keep accepting aggregator base_urls unchanged.
    # Do NOT pre-emptively migrate before an official sunset notice — it
    # would break zero-config UX and aggregator users for no current gain.
    class DashScope < Base
      GENERATION_PATH   = "/api/v1/services/aigc/multimodal-generation/generation"
      SPEECH_PATH_COSY  = "/api/v1/services/audio/tts/SpeechSynthesizer"
      VIDEO_PATH        = "/api/v1/services/aigc/video-generation/video-synthesis"
      TASK_PATH         = "/api/v1/tasks/"

      # Default voice per TTS model family. CosyVoice defaults to longanyang;
      # Qwen3-TTS defaults to Cherry (most common Chinese female voice).
      DEFAULT_SPEECH_VOICE_COSY = "longanyang"
      DEFAULT_SPEECH_VOICE_QWEN = "Cherry"

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

      # Synthesizes speech (TTS) using Alibaba CosyVoice models (e.g. cosyvoice-v3-flash).
      # This is a synchronous call.
      #
      # @param input [String] the text to synthesize
      # @param voice [String, nil] the voice name; defaults to "longanyang" for CosyVoice or "Cherry" for Qwen3-TTS
      # @param output_dir [String, nil] the directory to save the output audio
      # @param language_type [String, nil] language hint for Qwen3-TTS (default "Chinese"); ignored by CosyVoice
      # @return [Hash] audio_success_response or audio_error_response
      def generate_speech(input:, voice: nil, output_dir: nil, language_type: nil, **_kwargs)
        if input.to_s.strip.empty?
          return audio_error_response(
            error: "Input text is required and must be a non-empty string",
            error_type: "invalid_argument",
            provider: PROVIDER_ID,
            voice: voice.to_s
          )
        end

        if @api_key.to_s.empty?
          return audio_error_response(
            error: "api_key not configured for audio model '#{@model}'",
            error_type: "auth_required",
            provider: PROVIDER_ID,
            input: input,
            voice: voice.to_s
          )
        end

        # Pick endpoint and payload shape based on model family. CosyVoice
        # uses the dedicated TTS endpoint and accepts format/sample_rate;
        # Qwen3-TTS is a multimodal-generation model and expects
        # language_type instead.
        endpoint     = speech_endpoint
        chosen_voice = voice || default_speech_voice
        payload      = speech_payload(input: input, voice: chosen_voice, language_type: language_type)

        begin
          response = connection.post(endpoint) do |req|
            req.headers["Content-Type"]  = "application/json"
            req.headers["Authorization"] = "Bearer #{@api_key}"
            req.body = JSON.generate(payload)
          end
        rescue Faraday::Error => e
          return audio_error_response(
            error: "HTTP request failed: #{e.message}",
            error_type: "network_error",
            provider: PROVIDER_ID,
            input: input,
            voice: voice.to_s
          )
        end

        body = parse_json(response.body)
        unless body.is_a?(Hash)
          return audio_error_response(
            error: "Invalid JSON response from upstream",
            error_type: "invalid_response",
            provider: PROVIDER_ID,
            input: input,
            voice: voice.to_s
          )
        end

        # Inspect any business level errors from DashScope
        if body["code"] && !body["code"].to_s.empty?
          err_msg = body["message"].to_s
          if err_msg.include?("url error") && @base_url.to_s.include?("dashscope.aliyuncs.com")
            err_msg += " (Note: Alibaba Model Studio non-real-time TTS does not support the public shared endpoint. " \
                       "Set the model's Base URL to your dedicated MaaS domain, e.g. " \
                       "https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com)"
          end
          return audio_error_response(
            error: "Upstream error #{body["code"]}: #{err_msg}",
            error_type: "api_error",
            provider: PROVIDER_ID,
            input: input,
            voice: voice.to_s
          )
        end

        unless response.success?
          return audio_error_response(
            error: "Upstream #{response.status}: #{truncate(response.body, 500)}",
            error_type: "api_error",
            provider: PROVIDER_ID,
            input: input,
            voice: voice.to_s
          )
        end

        audio_url = body.dig("output", "audio", "url")
        if audio_url.nil? || audio_url.empty?
          return audio_error_response(
            error: "Upstream returned no audio data",
            error_type: "empty_response",
            provider: PROVIDER_ID,
            input: input,
            voice: voice.to_s
          )
        end

        # Download the audio file from OSS and save it locally in the target output directory
        local_path = save_image_from_url(audio_url, output_dir: output_dir || Dir.pwd, prefix: "tts", extension: "wav")
        if local_path.nil?
          return audio_error_response(
            error: "Failed to download generated audio from #{audio_url}",
            error_type: "download_failed",
            provider: PROVIDER_ID,
            input: input,
            voice: voice.to_s
          )
        end

        audio_success_response(
          audio: local_path,
          input: input,
          voice: chosen_voice,
          provider: PROVIDER_ID,
          extra: {
            "request_id" => body["request_id"]
          }.compact
        )
      end

      # Generates a video using Alibaba HappyHorse or Wanx models.
      # This is a mandatory asynchronous API. We submit the task, and poll
      # the task status until it succeeds, fails, or times out.
      #
      # @param prompt [String] the video prompt
      # @param aspect_ratio [String] "landscape", "portrait", or "square"
      # @param duration_seconds [Integer, nil] duration in seconds
      # @param output_dir [String, nil] the directory to save the output video
      # @return [Hash] video_success_response or video_error_response
      def generate_video(prompt:, aspect_ratio: "landscape", duration_seconds: nil, output_dir: nil, **_kwargs)
        if prompt.to_s.strip.empty?
          return video_error_response(
            error: "Prompt is required and must be a non-empty string",
            error_type: "invalid_argument",
            provider: PROVIDER_ID,
            aspect_ratio: aspect_ratio
          )
        end

        if @api_key.to_s.empty?
          return video_error_response(
            error: "api_key not configured for video model '#{@model}'",
            error_type: "auth_required",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect_ratio
          )
        end

        # Map aspect ratio strings to Alibaba's ratio values (e.g. 16:9).
        ratio = case aspect_ratio
                when "portrait" then "9:16"
                when "square"   then "1:1"
                else "16:9"
                end

        # Construct payload. Ratio and resolution are placed under the "parameters" key.
        payload = {
          model: @model,
          input: {
            prompt: prompt
          },
          parameters: {
            resolution: "720P",
            ratio: ratio
          }
        }
        payload[:parameters][:duration] = duration_seconds if duration_seconds

        begin
          # Submit the task. Alibaba requires 'X-DashScope-Async: enable' header for video synthesis.
          response = connection.post(VIDEO_PATH) do |req|
            req.headers["Content-Type"]      = "application/json"
            req.headers["Authorization"]     = "Bearer #{@api_key}"
            req.headers["X-DashScope-Async"] = "enable"
            req.body = JSON.generate(payload)
          end
        rescue Faraday::Error => e
          return video_error_response(
            error: "HTTP request failed: #{e.message}",
            error_type: "network_error",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect_ratio
          )
        end

        body = parse_json(response.body)
        unless body.is_a?(Hash)
          return video_error_response(
            error: "Invalid JSON response from upstream",
            error_type: "invalid_response",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect_ratio
          )
        end

        if body["code"] && !body["code"].to_s.empty?
          return video_error_response(
            error: "Upstream error #{body["code"]}: #{body["message"]}",
            error_type: "api_error",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect_ratio
          )
        end

        unless response.success?
          return video_error_response(
            error: "Upstream #{response.status}: #{truncate(response.body, 500)}",
            error_type: "api_error",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect_ratio
          )
        end

        task_id = body.dig("output", "task_id")
        if task_id.nil? || task_id.empty?
          return video_error_response(
            error: "Upstream did not return a task_id",
            error_type: "empty_response",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect_ratio
          )
        end

        # Poll the task status asynchronously. Alibaba limits video tasks, so we check
        # status at interval blocks until completion or timeout.
        max_duration = 300
        interval     = 5
        elapsed      = 0
        video_url    = nil
        polling_err  = nil

        while elapsed < max_duration
          begin
            task_resp = connection.get("#{TASK_PATH}#{task_id}") do |req|
              req.headers["Authorization"] = "Bearer #{@api_key}"
            end
          rescue Faraday::Error => e
            polling_err = "Polling request failed: #{e.message}"
            break
          end

          task_body = parse_json(task_resp.body)
          unless task_body.is_a?(Hash)
            polling_err = "Invalid polling response JSON"
            break
          end

          task_output = task_body["output"] || {}
          status = task_output["task_status"]

          if status == "SUCCEEDED"
            video_url = task_output["video_url"]
            break
          elsif status == "FAILED"
            polling_err = "Task failed: #{task_output["message"] || 'Unknown error'}"
            break
          elsif status == "CANCELED"
            polling_err = "Task was canceled"
            break
          end

          sleep interval
          elapsed += interval
        end

        if video_url.nil?
          return video_error_response(
            error: polling_err || "Polling timed out after #{max_duration} seconds",
            error_type: "polling_failed",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect_ratio
          )
        end

        # Download the final MP4 video file and save it locally
        local_path = save_image_from_url(video_url, output_dir: output_dir || Dir.pwd, prefix: "vid", extension: "mp4")
        if local_path.nil?
          return video_error_response(
            error: "Failed to download generated video from #{video_url}",
            error_type: "download_failed",
            provider: PROVIDER_ID,
            prompt: prompt,
            aspect_ratio: aspect_ratio
          )
        end

        video_success_response(
          video: local_path,
          prompt: prompt,
          aspect_ratio: aspect_ratio,
          provider: PROVIDER_ID,
          extra: {
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

      # CosyVoice models (cosyvoice-*, cosyvoice-v3-flash, etc.) use the
      # dedicated TTS endpoint; Qwen3-TTS models (qwen3-tts-flash,
      # qwen3-tts-instruct-flash) are served via the multimodal-generation
      # endpoint despite being TTS — see Aliyun docs:
      # https://help.aliyun.com/zh/model-studio/qwen-tts-api
      #
      # Matching is POSITIVE (by model-name pattern) so third-party
      # aggregators that keep the official model names keep working, and
      # unknown TTS models are not silently misrouted. Anything not
      # recognized as Qwen3-TTS falls back to the CosyVoice endpoint for
      # backward compatibility — every TTS model clacky supported before
      # qwen3-tts was a CosyVoice model.
      private def speech_endpoint
        m = @model.to_s
        if m.match?(/(^|[-_])qwen3-tts(-|$)/i)
          GENERATION_PATH
        else
          SPEECH_PATH_COSY
        end
      end

      private def default_speech_voice
        speech_endpoint == GENERATION_PATH ? DEFAULT_SPEECH_VOICE_QWEN : DEFAULT_SPEECH_VOICE_COSY
      end

      # Each model family has its own payload shape. We branch on endpoint
      # because the endpoint identity uniquely identifies the family here.
      private def speech_payload(input:, voice:, language_type: nil)
        input_body = { text: input, voice: voice }
        if speech_endpoint == GENERATION_PATH
          # Qwen3-TTS expects language_type; default to Chinese when caller
          # doesn't specify, since most users run Chinese TTS.
          input_body[:language_type] = (language_type.to_s.empty? ? "Chinese" : language_type)
        else
          # CosyVoice expects format + sample_rate.
          input_body[:format]      = "wav"
          input_body[:sample_rate] = 24000
        end
        { model: @model, input: input_body }
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
