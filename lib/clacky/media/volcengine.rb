# frozen_string_literal: true

require "faraday"
require "json"
require "uri"
require "base64"
require_relative "base"

module Clacky
  module Media
    # Volcengine Ark (ByteDance Doubao Seedance) video generation provider.
    #
    # Ark is NOT OpenAI-compatible for video. It uses an asynchronous task
    # model with its own request envelope: submit a task to
    # POST /api/v3/contents/generations/tasks, then poll
    # GET /api/v3/contents/generations/tasks/{id} until it succeeds, fails,
    # or expires. Unlike the blocking Veo path, we surface that async model
    # end to end: #generate_video submits and returns the task id immediately,
    # and #video_status polls a single time (downloading the MP4 once the task
    # has succeeded). This keeps a slow (e.g. 4k) render from blocking the HTTP
    # request past its timeout and dropping the task id.
    #
    # Routing: Generator sends any base_url under *.volces.com here. We
    # derive the API root from the host so users can paste the standard
    # base_url they use for Ark chat models (…/api/v3) and still get working
    # video generation.
    #
    # Seedance content is multimodal: alongside the text prompt, callers may
    # attach a first frame, a last frame, reference images (0-9), reference
    # videos (0-3) and reference audios (0-3). Each media item may be a
    # public http(s) URL, a data URL, a local file path (encoded to a data
    # URL), or a { "b64_json" => ..., "mime_type" => ... } hash.
    class Volcengine < Base
      TASKS_PATH  = "/api/v3/contents/generations/tasks"
      PROVIDER_ID = "volcengine"

      # aspect_ratio -> Ark ratio. Ark also accepts more granular ratios and
      # "adaptive"; when the caller passes one of those verbatim we forward it
      # unchanged (see #resolve_ratio).
      ASPECT_TO_RATIO = {
        "landscape" => "16:9",
        "portrait"  => "9:16",
        "square"    => "1:1"
      }.freeze

      # Ratios Ark accepts directly. Anything else falls back to the
      # aspect_ratio mapping / default.
      ARK_RATIOS = %w[16:9 4:3 1:1 3:4 9:16 21:9 adaptive].freeze

      DEFAULT_RATIO = "16:9"

      # Explicit cost-control default: when the caller omits resolution we pin
      # 720p rather than relying on Ark's server-side default (which could
      # change and silently raise the user's bill).
      DEFAULT_RESOLUTION = "720p"

      # @param prompt [String] the video prompt (may be empty when driven
      #   purely by reference media, but Ark still recommends text)
      # @param aspect_ratio [String] "landscape"/"portrait"/"square", or an
      #   Ark ratio string ("16:9", "9:16", "adaptive", ...)
      # @param duration_seconds [Integer, nil] target duration; -1 lets the
      #   model choose (Seedance 2.0 / 1.5 Pro only)
      # @param first_frame [String, Hash, nil] first frame image
      # @param last_frame [String, Hash, nil] last frame image
      # @param reference_images [Array, String, Hash, nil] reference images
      # @param reference_videos [Array, String, Hash, nil] reference videos
      # @param reference_audios [Array, String, Hash, nil] reference audios
      # @param resolution [String, nil] "480p"/"720p"/"1080p"/"4k"
      # @param generate_audio [Boolean, nil] whether to synthesize audio
      # @param watermark [Boolean, nil] whether to add a watermark
      # @param seed [Integer, nil] random seed
      def generate_video(prompt:, aspect_ratio: "landscape", duration_seconds: nil, output_dir: nil,
                         image: nil, first_frame: nil, last_frame: nil,
                         reference_images: nil, reference_videos: nil, reference_audios: nil,
                         resolution: nil, generate_audio: nil, watermark: nil, seed: nil, **_kwargs)
        # `image` is the legacy single first-frame field used across the media
        # stack; treat it as first_frame when no explicit first_frame is given.
        first_frame ||= image

        content, build_err = build_content(
          prompt: prompt,
          first_frame: first_frame,
          last_frame: last_frame,
          reference_images: reference_images,
          reference_videos: reference_videos,
          reference_audios: reference_audios
        )
        if build_err
          return video_error_response(
            error: build_err, error_type: "invalid_argument",
            provider: PROVIDER_ID, prompt: prompt, aspect_ratio: aspect_ratio
          )
        end

        has_text  = prompt.to_s.strip != ""
        has_media = content.length > (has_text ? 1 : 0)
        if !has_text && !has_media
          return video_error_response(
            error: "A text prompt or at least one reference image/video is required",
            error_type: "invalid_argument",
            provider: PROVIDER_ID, prompt: prompt, aspect_ratio: aspect_ratio
          )
        end

        if @api_key.to_s.empty?
          return video_error_response(
            error: "api_key not configured for video model '#{@model}'",
            error_type: "auth_required",
            provider: PROVIDER_ID, prompt: prompt, aspect_ratio: aspect_ratio
          )
        end

        ratio   = resolve_ratio(aspect_ratio)
        payload = { model: @model, content: content }
        payload[:ratio]          = ratio unless ratio.nil?
        payload[:duration]       = duration_seconds.to_i if duration_seconds
        payload[:resolution]     = (resolution && !resolution.to_s.empty?) ? resolution.to_s : DEFAULT_RESOLUTION
        payload[:generate_audio] = generate_audio unless generate_audio.nil?
        payload[:watermark]      = watermark unless watermark.nil?
        payload[:seed]           = seed.to_i if seed

        begin
          response = connection.post(TASKS_PATH) do |req|
            req.headers["Content-Type"]  = "application/json"
            req.headers["Authorization"] = "Bearer #{@api_key}"
            req.body = JSON.generate(payload)
          end
        rescue Faraday::Error => e
          return video_error_response(
            error: "HTTP request failed: #{e.message}",
            error_type: "network_error",
            provider: PROVIDER_ID, prompt: prompt, aspect_ratio: aspect_ratio
          )
        end

        body = parse_json(response.body)
        unless body.is_a?(Hash)
          return video_error_response(
            error: "Invalid JSON response from upstream",
            error_type: "invalid_response",
            provider: PROVIDER_ID, prompt: prompt, aspect_ratio: aspect_ratio
          )
        end

        # Ark reports submission errors via a nested "error" object.
        if body["error"].is_a?(Hash)
          err = body["error"]
          return video_error_response(
            error: "Upstream error #{err["code"]}: #{err["message"]}",
            error_type: "api_error",
            provider: PROVIDER_ID, prompt: prompt, aspect_ratio: aspect_ratio
          )
        end

        unless response.success?
          return video_error_response(
            error: "Upstream #{response.status}: #{truncate(response.body, 500)}",
            error_type: "api_error",
            provider: PROVIDER_ID, prompt: prompt, aspect_ratio: aspect_ratio
          )
        end

        task_id = body["id"]
        if task_id.nil? || task_id.to_s.empty?
          return video_error_response(
            error: "Upstream did not return a task id",
            error_type: "empty_response",
            provider: PROVIDER_ID, prompt: prompt, aspect_ratio: aspect_ratio
          )
        end

        # Submit only: return the task id immediately. The caller polls
        # GET /api/media/video/status so a long (e.g. 4k) render never blocks
        # the HTTP request past its timeout — which used to drop the task id
        # and push the model into resubmitting, doubling the bill.
        {
          "success"      => true,
          "status"       => "submitted",
          "task_id"      => task_id,
          "provider"     => PROVIDER_ID,
          "model"        => @model,
          "prompt"       => prompt,
          "aspect_ratio" => aspect_ratio,
          "ratio"        => ratio,
          "duration_seconds" => (duration_seconds ? duration_seconds.to_i : nil)
        }.compact
      end

      # Poll a previously submitted task once. On "succeeded" the MP4 is
      # downloaded and a local path is returned; other states map to
      # running / failed without blocking.
      def video_status(task_id:, output_dir: nil)
        if task_id.to_s.strip.empty?
          return video_error_response(
            error: "task_id is required", error_type: "invalid_argument",
            provider: PROVIDER_ID
          )
        end

        state, detail = fetch_task(task_id)
        case state
        when :running
          { "success" => true, "status" => "running", "task_id" => task_id, "provider" => PROVIDER_ID, "model" => @model }
        when :succeeded
          local_path = save_image_from_url(detail, output_dir: output_dir || Dir.pwd, prefix: "vid", extension: "mp4")
          if local_path.nil?
            return {
              "success" => false, "status" => "failed", "task_id" => task_id, "provider" => PROVIDER_ID,
              "model" => @model, "error" => "Failed to download generated video from #{detail}",
              "error_type" => "download_failed"
            }
          end
          {
            "success" => true, "status" => "succeeded", "video" => local_path,
            "task_id" => task_id, "provider" => PROVIDER_ID, "model" => @model
          }
        else # :failed
          {
            "success" => false, "status" => "failed", "task_id" => task_id, "provider" => PROVIDER_ID,
            "model" => @model, "error" => detail, "error_type" => "task_failed"
          }
        end
      end

      # Query a task once (no sleeping/looping). Returns one of:
      #   [:running, nil]
      #   [:succeeded, video_url]
      #   [:failed, error_message]
      private def fetch_task(task_id)
        begin
          resp = connection.get("#{TASKS_PATH}/#{task_id}") do |req|
            req.headers["Authorization"] = "Bearer #{@api_key}"
          end
        rescue Faraday::Error => e
          return [:failed, "Polling request failed: #{e.message}"]
        end

        task = parse_json(resp.body)
        return [:failed, "Invalid polling response JSON"] unless task.is_a?(Hash)

        case task["status"]
        when "succeeded"
          url = task.dig("content", "video_url")
          return [:failed, "Task succeeded but returned no video_url"] if url.nil? || url.empty?
          [:succeeded, url]
        when "failed"
          msg = task.dig("error", "message") || task["error"] || "Unknown error"
          [:failed, "Task failed: #{msg}"]
        when "cancelled", "canceled"
          [:failed, "Task was cancelled"]
        when "expired"
          [:failed, "Task expired before completion"]
        else # "queued" / "running"
          [:running, nil]
        end
      end

      # Build the Ark content[] array. Returns [content, nil] on success or
      # [nil, error_message] when a media item can't be resolved.
      private def build_content(prompt:, first_frame:, last_frame:, reference_images:, reference_videos:, reference_audios:)
        has_frame     = !normalize_list(first_frame).empty? || !normalize_list(last_frame).empty?
        has_reference = !normalize_list(reference_images).empty? ||
                        !normalize_list(reference_videos).empty? ||
                        !normalize_list(reference_audios).empty?
        if has_frame && has_reference
          return [nil, "first_frame/last_frame cannot be combined with reference_images/videos/audios. " \
                       "Use first_frame (and optionally last_frame) for first/last-frame image-to-video, " \
                       "OR use reference_* for multimodal / video editing / video extension — not both."]
        end

        content = []
        content << { type: "text", text: prompt.to_s } unless prompt.to_s.strip.empty?

        {
          "first_frame"     => normalize_list(first_frame),
          "last_frame"      => normalize_list(last_frame),
          "reference_image" => normalize_list(reference_images)
        }.each do |role, items|
          items.each do |item|
            url, err = to_media_url(item, kind: :image)
            return [nil, err] if err
            content << { type: "image_url", image_url: { url: url }, role: role }
          end
        end

        normalize_list(reference_videos).each do |item|
          url, err = to_media_url(item, kind: :video)
          return [nil, err] if err
          content << { type: "video_url", video_url: { url: url }, role: "reference_video" }
        end

        normalize_list(reference_audios).each do |item|
          url, err = to_media_url(item, kind: :audio)
          return [nil, err] if err
          content << { type: "audio_url", audio_url: { url: url }, role: "reference_audio" }
        end

        [content, nil]
      end

      # Accept a single value or an array; drop nils/blanks.
      private def normalize_list(value)
        list = value.is_a?(Array) ? value : [value]
        list.reject { |v| v.nil? || (v.is_a?(String) && v.strip.empty?) }
      end

      # Resolve one media item into a URL Ark accepts (http(s) URL or data
      # URL). Accepts: an http(s)/data URL string, a local file path, or a
      # { "b64_json" => ..., "mime_type" => ... } hash. Returns [url, nil] or
      # [nil, error_message].
      private def to_media_url(item, kind:)
        if item.is_a?(Hash)
          b64  = item["b64_json"] || item[:b64_json]
          mime = (item["mime_type"] || item[:mime_type]).to_s
          return [nil, "media hash is missing b64_json"] if b64.to_s.empty?
          mime = default_mime(kind) if mime.empty?
          return ["data:#{mime};base64,#{b64}", nil]
        end

        s = item.to_s.strip
        return [nil, "empty media reference"] if s.empty?
        return [s, nil] if s.start_with?("http://", "https://", "data:")

        unless File.file?(s)
          return [nil, "media reference is neither an existing file path, a URL, nor base64 data: #{s}"]
        end
        bytes = File.binread(s)
        mime  = mime_for_path(s, kind)
        ["data:#{mime};base64,#{Base64.strict_encode64(bytes)}", nil]
      end

      private def resolve_ratio(aspect_ratio)
        s = aspect_ratio.to_s
        return s if ARK_RATIOS.include?(s)
        ASPECT_TO_RATIO[s] || DEFAULT_RATIO
      end

      private def default_mime(kind)
        case kind
        when :video then "video/mp4"
        when :audio then "audio/mpeg"
        else "image/png"
        end
      end

      private def mime_for_path(path, kind)
        case File.extname(path).downcase
        when ".jpg", ".jpeg" then "image/jpeg"
        when ".webp"         then "image/webp"
        when ".gif"          then "image/gif"
        when ".mp4"          then "video/mp4"
        when ".mov"          then "video/quicktime"
        when ".webm"         then "video/webm"
        when ".mp3"          then "audio/mpeg"
        when ".wav"          then "audio/wav"
        when ".m4a"          then "audio/mp4"
        else default_mime(kind)
        end
      end

      private def connection
        Faraday.new(url: endpoint_base) do |f|
          f.options.timeout      = 240
          f.options.open_timeout = 10
        end
      end

      # Derive the API root (scheme + host) from the configured base_url,
      # discarding any path the user pasted (e.g. /api/v3). The task path is
      # appended by the request methods. Falls back to the Beijing host.
      private def endpoint_base
        uri = URI.parse(@base_url.to_s)
        if uri.scheme && uri.host
          "#{uri.scheme}://#{uri.host}"
        else
          "https://ark.cn-beijing.volces.com"
        end
      rescue URI::InvalidURIError
        "https://ark.cn-beijing.volces.com"
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
