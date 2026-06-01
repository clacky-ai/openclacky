# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  class Client
    MAX_RETRIES = 10
    RETRY_DELAY = 5 # seconds

    attr_reader :provider_id

    def initialize(api_key, base_url:, model:, anthropic_format: false, read_timeout: nil)
      @api_key = api_key
      @base_url = base_url
      @model = model
      # Detect Bedrock: ABSK key prefix (native AWS) or abs- model prefix (Clacky AI proxy)
      @use_bedrock = MessageFormat::Bedrock.bedrock_api_key?(api_key, model)

      # Resolve provider once — reused for capability + api-type lookups.
      provider_id = Providers.resolve_provider(base_url: @base_url, api_key: @api_key)

      # Decide anthropic_format dynamically based on provider+model, falling
      # back to the explicit constructor flag for unknown providers / custom
      # base_urls. This lets e.g. OpenRouter's Claude models auto-route to the
      # native /v1/messages endpoint (preserving cache_control byte-for-byte)
      # without requiring any change to user YAML.
      provider_prefers_anthropic = provider_id &&
                                   Providers.anthropic_format_for_model?(provider_id, @model)
      @use_anthropic_format = provider_prefers_anthropic || anthropic_format

      # Remember the provider id so we can tune connection headers below
      # (OpenRouter's /v1/messages accepts either Bearer or x-api-key, but
      # some OpenRouter-compatible relays only honour Bearer — send both).
      @provider_id = provider_id

      # Determine vision support once at construction time.
      # Non-vision models (DeepSeek, Kimi, MiniMax, etc.) reject image_url
      # content blocks; the conversion layer strips them when this is false.
      @vision_supported = Providers.supports?(provider_id, :vision, model_name: @model)

      # Optional override for Faraday read_timeout (e.g. benchmark calls).
      # nil means use the default (300s for streaming).
      @read_timeout = read_timeout
    end

    # Returns true when the client is using the AWS Bedrock Converse API.
    def bedrock?
      @use_bedrock
    end

    # Returns true when the client is talking directly to the Anthropic API
    # (determined at construction time via the anthropic_format flag).
    def anthropic_format?(model = nil)
      @use_anthropic_format && !@use_bedrock
    end

    # ── Connection test ───────────────────────────────────────────────────────

    # Test API connection by sending a minimal request.
    # Returns { success: true } or { success: false, error: "..." }.
    def test_connection(model:)
      if bedrock?
        body = MessageFormat::Bedrock.build_request_body(
          [{ role: :user, content: "hi" }], model, [], 16
        ).to_json
        response = bedrock_connection.post(bedrock_endpoint(model)) { |r| r.body = body }
      elsif anthropic_format?
        minimal_body = { model: model, max_tokens: 16,
                         messages: [{ role: "user", content: "hi" }] }.to_json
        response = anthropic_connection.post(anthropic_messages_path) { |r| r.body = minimal_body }
      else
        minimal_body = { model: model, max_tokens: 16,
                         messages: [{ role: "user", content: "hi" }] }.to_json
        response = openai_connection.post("chat/completions") { |r| r.body = minimal_body }
      end
      handle_test_response(response)
    rescue Faraday::Error => e
      { success: false, error: "Connection error: #{e.message}" }
    rescue => e
      Clacky::Logger.error("[test_connection] #{e.class}: #{e.message}", error: e)
      { success: false, error: e.message }
    end

    # ── Simple (non-agent) helpers ────────────────────────────────────────────

    # Send a single string message and return the reply text.
    def send_message(content, model:, max_tokens:)
      messages = [{ role: "user", content: content }]
      send_messages(messages, model: model, max_tokens: max_tokens)
    end

    # Send a messages array and return the reply text.
    def send_messages(messages, model:, max_tokens:)
      if bedrock?
        body     = MessageFormat::Bedrock.build_request_body(messages, model, [], max_tokens)
        response = bedrock_connection.post(bedrock_endpoint(model)) { |r| r.body = body.to_json }
        parse_simple_bedrock_response(response)
      elsif anthropic_format?
        body     = MessageFormat::Anthropic.build_request_body(messages, model, [], max_tokens, false)
        response = anthropic_connection.post(anthropic_messages_path) { |r| r.body = body.to_json }
        parse_simple_anthropic_response(response)
      else
        body     = { model: model, max_tokens: max_tokens, messages: messages }
        response = openai_connection.post("chat/completions") { |r| r.body = body.to_json }
        parse_simple_openai_response(response)
      end
    end

    # ── Agent main path ───────────────────────────────────────────────────────

    # Send messages with tool-calling support.
    # Returns canonical response hash: { content:, tool_calls:, finish_reason:, usage:, latency: }
    #
    # Latency measurement:
    #   Because the current HTTP path is *non-streaming* (plain POST, response
    #   body read in one shot), TTFB (time to response headers) is not exposed
    #   by Faraday's default adapter without extra plumbing. What we CAN measure
    #   cheaply — and what users actually feel — is total request duration,
    #   which for a non-streaming call equals the time from "hit Enter" to
    #   "first token visible" (since we receive everything at once).
    #
    #   So we record `duration_ms` as the authoritative number and alias it to
    #   `ttft_ms` for downstream consumers (status bar uses ttft_ms as its
    #   signal metric — see docs). When we migrate to streaming later, this
    #   same `ttft_ms` field will start carrying the *actual* first-token
    #   latency without any schema change.
    # @param on_chunk [Proc, nil] optional streaming progress callback.
    #   Receives keyword args { input_tokens:, output_tokens: } with cumulative
    #   token counts. When nil, behaves exactly as the historical non-streaming
    #   path. When given but streaming is not yet wired for the active provider,
    #   a single synthetic invocation is fired after the response is received,
    #   so UI plumbing can be exercised end-to-end without the proxy work.
    def send_messages_with_tools(messages, model:, tools:, max_tokens:, enable_caching: false, reasoning_effort: nil, on_chunk: nil)
      caching_enabled = enable_caching && supports_prompt_caching?(model)
      cloned = deep_clone(messages)

      streaming_used = false
      first_chunk_at = nil
      wrapped_on_chunk = on_chunk && lambda do |**kwargs|
        first_chunk_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        on_chunk.call(**kwargs)
      end

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response =
        if bedrock?
          streaming_used = !on_chunk.nil?
          send_bedrock_request(cloned, model, tools, max_tokens, caching_enabled, reasoning_effort: reasoning_effort, on_chunk: wrapped_on_chunk)
        elsif anthropic_format?
          streaming_used = !on_chunk.nil?
          send_anthropic_request(cloned, model, tools, max_tokens, caching_enabled, reasoning_effort: reasoning_effort, on_chunk: wrapped_on_chunk)
        else
          streaming_used = !on_chunk.nil?
          send_openai_request(cloned, model, tools, max_tokens, caching_enabled, reasoning_effort: reasoning_effort, on_chunk: wrapped_on_chunk)
        end
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if on_chunk && !streaming_used
        usage = response[:usage] || {}
        safe_invoke_on_chunk(
          on_chunk,
          input_tokens:  usage[:prompt_tokens].to_i,
          output_tokens: usage[:completion_tokens].to_i
        )
      end

      duration_ms = ((t1 - t0) * 1000).round
      ttft_ms = first_chunk_at ? ((first_chunk_at - t0) * 1000).round : duration_ms
      output_tokens = response[:usage]&.dig(:completion_tokens).to_i
      tps = (output_tokens >= 10 && duration_ms > 0) ? (output_tokens * 1000.0 / duration_ms).round(1) : nil

      response[:latency] = {
        ttft_ms:     ttft_ms,
        duration_ms: duration_ms,
        output_tokens: output_tokens,
        tps:         tps,
        model:       model,
        measured_at: Time.now.to_f,
        streaming:   streaming_used
      }
      response
    end

    # Format tool results into canonical messages ready to append to @messages.
    # Always returns canonical format (role: "tool") regardless of API type —
    # conversion to API-native happens inside each send_*_request.
    def format_tool_results(response, tool_results, model:)
      return [] if tool_results.empty?

      if bedrock?
        MessageFormat::Bedrock.format_tool_results(response, tool_results)
      elsif anthropic_format?
        MessageFormat::Anthropic.format_tool_results(response, tool_results)
      else
        MessageFormat::OpenAI.format_tool_results(response, tool_results)
      end
    end

    # ── Prompt-caching support ────────────────────────────────────────────────

    # Returns true for Claude models that support prompt caching (gen 3.5+ or gen 4+).
    #
    # Handles both direct model names (e.g. "claude-haiku-4-5") and
    # Clacky AI Bedrock proxy names with "abs-" prefix (e.g. "abs-claude-haiku-4-5").
    #
    # Why only Claude models:
    #   - MiniMax uses automatic server-side caching (no cache_control needed from client)
    #   - Kimi uses a proprietary prompt_cache_key param, not cache_control
    #   - MiMo has no documented caching API
    #   - Only Claude (direct, OpenRouter, or ClackyAI Bedrock proxy) consumes our
    #     cache_control / cachePoint markers
    def supports_prompt_caching?(model)
      # Strip ClackyAI Bedrock proxy prefix before matching
      model_str = model.to_s.downcase.sub(/^abs-/, "")
      return false unless model_str.include?("claude")

      # Match Claude gen 3.5+ (3.5/3.6/3.7…) or gen 4+ in any name format:
      #   claude-3.5-sonnet-...  claude-3-7-sonnet  claude-haiku-4-5  claude-sonnet-4-6
      model_str.match?(/claude(?:-3[-.]?[5-9]|.*-[4-9][-.]|.*-[4-9]$|-[4-9][-.]|-[4-9]$|-sonnet-[34])/)
    end


    # ── Bedrock Converse request / response ───────────────────────────────────

    def send_bedrock_request(messages, model, tools, max_tokens, caching_enabled, reasoning_effort: nil, on_chunk: nil)
      body = MessageFormat::Bedrock.build_request_body(messages, model, tools, max_tokens, caching_enabled, reasoning_effort: reasoning_effort)
      return send_bedrock_stream_request(body, model, on_chunk) if on_chunk

      response = bedrock_connection.post(bedrock_endpoint(model)) { |r| r.body = body.to_json }

      raise_error(response) unless response.status == 200
      check_html_response(response)
      parsed_body = safe_json_parse(response.body, context: "LLM response")
      MessageFormat::Bedrock.parse_response(parsed_body)
    end

    # Streaming variant for Bedrock Converse.
    # Posts to /model/{m}/converse-stream with stream:true; the proxy returns
    # SSE frames whose `event` is the Bedrock event-type and whose `data` is
    # the raw Bedrock event JSON. We accumulate frames into a synthetic
    # non-streaming response and feed it back through the existing parser so
    # downstream code is identical.
    private def send_bedrock_stream_request(body, model, on_chunk)
      stream_body = body.merge(stream: true)
      aggregator = BedrockStreamAggregator.new(on_chunk: on_chunk)
      sse_buf = +""

      response = bedrock_connection.post(bedrock_stream_endpoint(model)) do |req|
        req.body = stream_body.to_json
        req.options.on_data = proc do |chunk, _bytes_received, _env|
          sse_buf << chunk
          drain_sse_frames(sse_buf) { |event, data| aggregator.handle(event, data) }
        end
      end

      unless response.status == 200
        response.env.body = sse_buf if response.body.to_s.empty?
        raise_error(response)
      end

      result = aggregator.to_h
      # A complete Converse stream always emits stopReason in its messageStop
      # frame. Its absence means the upstream cut the stream mid-response,
      # leaving a half-written message; retry rather than accept the truncation.
      if result["stopReason"].nil?
        raise Clacky::UpstreamTruncatedError,
          "[LLM] Streaming response ended without stopReason (upstream cut the stream). Retrying..."
      end
      MessageFormat::Bedrock.parse_response(result)
    end

    def parse_simple_bedrock_response(response)
      raise_error(response) unless response.status == 200
      data = safe_json_parse(response.body, context: "LLM response")
      (data.dig("output", "message", "content") || [])
        .select { |b| b["text"] }
        .map { |b| b["text"] }
        .join("")
    end

    # ── Anthropic request / response ──────────────────────────────────────────

    def send_anthropic_request(messages, model, tools, max_tokens, caching_enabled, reasoning_effort: nil, on_chunk: nil)
      # Apply cache_control to the message that marks the cache breakpoint
      messages = apply_message_caching(messages) if caching_enabled

      body = MessageFormat::Anthropic.build_request_body(messages, model, tools, max_tokens, caching_enabled, reasoning_effort: reasoning_effort)
      return send_anthropic_stream_request(body, on_chunk) if on_chunk

      response = anthropic_connection.post(anthropic_messages_path) { |r| r.body = body.to_json }

      raise_error(response) unless response.status == 200
      check_html_response(response)
      parsed_body = safe_json_parse(response.body, context: "LLM response")
      MessageFormat::Anthropic.parse_response(parsed_body)
    end

    private def send_anthropic_stream_request(body, on_chunk)
      stream_body = body.merge(stream: true)
      aggregator = AnthropicStreamAggregator.new(on_chunk: on_chunk)
      sse_buf = +""

      response = anthropic_connection.post(anthropic_messages_path) do |req|
        req.headers["Accept"] = "text/event-stream"
        req.body = stream_body.to_json
        req.options.on_data = proc do |chunk, _bytes_received, _env|
          sse_buf << chunk
          drain_sse_frames(sse_buf) { |event, data| aggregator.handle(event, data) }
        end
      end

      unless response.status == 200
        recovered_body = response.body.to_s
        recovered_body = sse_buf.to_s if recovered_body.empty?
        recovered = Struct.new(:status, :body).new(response.status, recovered_body)
        raise_error(recovered)
      end

      result = aggregator.to_h
      # A complete Messages stream always emits stop_reason in its message_delta
      # frame. Its absence means the upstream cut the stream mid-response,
      # leaving a half-written message; retry rather than accept the truncation.
      if result["stop_reason"].nil?
        raise Clacky::UpstreamTruncatedError,
          "[LLM] Streaming response ended without stop_reason (upstream cut the stream). Retrying..."
      end
      MessageFormat::Anthropic.parse_response(result)
    end

    def parse_simple_anthropic_response(response)
      raise_error(response) unless response.status == 200
      data = safe_json_parse(response.body, context: "LLM response")
      (data["content"] || []).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("")
    end

    # ── OpenAI request / response ─────────────────────────────────────────────

    def send_openai_request(messages, model, tools, max_tokens, caching_enabled, reasoning_effort: nil, on_chunk: nil)
      # Apply cache_control markers to messages when caching is enabled.
      # OpenRouter proxies Claude with the same cache_control field convention as Anthropic direct.
      messages = apply_message_caching(messages) if caching_enabled

      body = MessageFormat::OpenAI.build_request_body(
        messages, model, tools, max_tokens, caching_enabled,
        vision_supported: @vision_supported,
        reasoning_effort: reasoning_effort
      )
      return send_openai_stream_request(body, on_chunk) if on_chunk

      response = openai_connection.post("chat/completions") { |r| r.body = body.to_json }

      raise_error(response) unless response.status == 200
      check_html_response(response)

      parsed_body = safe_json_parse(response.body, context: "LLM response")
      MessageFormat::OpenAI.parse_response(parsed_body)
    end

    # Streaming variant for OpenAI-compatible chat completions (DeepSeek/OpenRouter
    # via platform/llm_proxy). Uses Faraday's on_data hook to consume SSE frames,
    # accumulates them, and reconstructs the non-streaming JSON response shape so
    # MessageFormat::OpenAI.parse_response works unchanged.
    private def send_openai_stream_request(body, on_chunk)
      stream_body = body.merge(stream: true, stream_options: { include_usage: true })
      aggregator = OpenAIStreamAggregator.new(on_chunk: on_chunk)
      sse_buf = +""

      response = openai_connection.post("chat/completions") do |req|
        req.body = stream_body.to_json
        req.options.on_data = proc do |chunk, _bytes_received, _env|
          sse_buf << chunk
          drain_sse_frames(sse_buf) { |_event, data| aggregator.handle(data) }
        end
      end

      unless response.status == 200
        response.env.body = sse_buf if response.body.to_s.empty?
        raise_error(response)
      end

      result = aggregator.to_h
      # A complete chat-completion stream always terminates with a frame
      # carrying finish_reason. Its absence means the upstream cut the stream
      # mid-response (e.g. proxy idle-timeout, connection reset that Faraday
      # didn't surface as an exception), leaving a half-written message. Treat
      # as retryable so we don't hand a silently truncated answer to the agent.
      if result.dig("choices", 0, "finish_reason").nil?
        raise Clacky::UpstreamTruncatedError,
          "[LLM] Streaming response ended without finish_reason (upstream cut the stream). Retrying..."
      end
      MessageFormat::OpenAI.parse_response(result)
    end

    def parse_simple_openai_response(response)
      raise_error(response) unless response.status == 200
      parsed_body = safe_json_parse(response.body, context: "LLM response")
      parsed_body["choices"].first["message"]["content"]
    end

    # ── Prompt caching helpers ────────────────────────────────────────────────

    # Add cache_control markers to the last 2 messages in the array.
    #
    # Why 2 markers:
    #   Turn N   — marks messages[-2] and messages[-1]; server caches prefix up to [-1]
    #   Turn N+1 — messages[-2] is Turn N's last message (still marked) → cache READ hit;
    #              messages[-1] is the new message (marked) → cache WRITE for Turn N+2
    #
    # With only 1 marker (old behavior): Turn N marks messages[-1]; in Turn N+1 that same
    # message is now [-2] and carries no marker → server sees a different prefix → cache MISS.
    #
    # Compression instructions (system_injected: true) are skipped — we never want to cache
    # those ephemeral injection messages.
    def apply_message_caching(messages)
      return messages if messages.empty?

      # Collect up to 2 candidate indices from the tail, skipping compression instructions.
      candidate_indices = []
      (messages.length - 1).downto(0) do |i|
        break if candidate_indices.length >= 2

        candidate_indices << i unless is_compression_instruction?(messages[i])
      end

      messages.map.with_index do |msg, idx|
        candidate_indices.include?(idx) ? add_cache_control_to_message(msg) : msg
      end
    end

    # Wrap or extend the message's content with a cache_control marker.
    def add_cache_control_to_message(msg)
      content = msg[:content]

      content_array = case content
                      when String
                        [{ type: "text", text: content, cache_control: { type: "ephemeral" } }]
                      when Array
                        content.map.with_index do |block, idx|
                          idx == content.length - 1 ? block.merge(cache_control: { type: "ephemeral" }) : block
                        end
                      else
                        return msg
                      end

      msg.merge(content: content_array)
    end

    def is_compression_instruction?(message)
      message.is_a?(Hash) && message[:system_injected] == true
    end

    # ── HTTP connections ──────────────────────────────────────────────────────

    # Bedrock Converse API endpoint path for a given model ID.
    def bedrock_endpoint(model)
      "/model/#{model}/converse"
    end

    # Bedrock Converse streaming endpoint path.
    private def bedrock_stream_endpoint(model)
      "/model/#{model}/converse-stream"
    end

    # Pull complete SSE frames out of a buffer and yield them as (event, data).
    # An SSE frame ends at a blank line ("\n\n"); incomplete trailing data
    # stays in the buffer for the next chunk. Frames without an explicit
    # `event:` line use the default "message" type per the SSE spec.
    private def drain_sse_frames(buf)
      while (sep = buf.index("\n\n"))
        frame = buf.slice!(0, sep + 2)
        event = "message"
        data_lines = []
        frame.each_line do |line|
          line = line.chomp
          if line.start_with?("event:")
            event = line.sub(/^event:\s*/, "")
          elsif line.start_with?("data:")
            data_lines << line.sub(/^data:\s*/, "")
          end
        end
        next if data_lines.empty?
        yield event, data_lines.join("\n")
      end
    end

    def bedrock_connection
      @bedrock_connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"]  = "application/json"
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.options.timeout      = @read_timeout || 300
        conn.options.open_timeout = 10
        conn.ssl.verify           = false
        conn.adapter Faraday.default_adapter
      end
    end

    def openai_connection
      @openai_connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"]  = "application/json"
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.options.timeout      = @read_timeout || 300
        conn.options.open_timeout = 10
        conn.ssl.verify           = false
        conn.adapter Faraday.default_adapter
      end
    end

    def anthropic_connection
      @anthropic_connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"]   = "application/json"
        conn.headers["x-api-key"]      = @api_key
        conn.headers["anthropic-version"] = "2023-06-01"
        conn.headers["anthropic-dangerous-direct-browser-access"] = "true"
        # OpenRouter's /v1/messages endpoint authenticates with a Bearer
        # token (the OpenRouter API key), not Anthropic's x-api-key. We send
        # both so the same connection code works for direct Anthropic and
        # for OpenRouter-proxied Claude — each endpoint ignores the header
        # it doesn't recognise.
        if @provider_id == "openrouter"
          conn.headers["Authorization"] = "Bearer #{@api_key}"
        end
        # Moonshot's Kimi Code (Coding Plan) endpoint enforces a User-Agent
        # prefix whitelist limited to first-party coding agents (Kimi CLI,
        # Claude Code, Roo Code, Kilo Code, ...). Requests with the default
        # Faraday UA are rejected with HTTP 403 access_terminated_error,
        # despite a valid API key. We send a Claude Code-shaped UA here
        # because openclacky talks to this endpoint over the same Anthropic
        # /v1/messages protocol that Claude Code uses, so the UA matches the
        # wire-level behaviour. Hardcoding rather than exposing as a config
        # field is intentional: the only UAs known to pass the gate are the
        # whitelisted-client formats, and the project's preset registry is
        # the single source of truth for provider-specific quirks (mirroring
        # how the openrouter Bearer-fallback above is hardcoded).
        if @provider_id == "kimi-coding"
          conn.headers["User-Agent"] = "claude-cli/1.0.51 (external, cli)"
        end
        conn.options.timeout      = @read_timeout || 300
        conn.options.open_timeout = 10
        conn.ssl.verify           = false
        conn.adapter Faraday.default_adapter
      end
    end

    # Correct relative path for the Anthropic /v1/messages endpoint, accounting
    # for whether the configured base_url already includes a "/v1" segment.
    #
    # Examples:
    #   base_url = "https://api.anthropic.com"         → "v1/messages"
    #   base_url = "https://openrouter.ai/api/v1"      → "messages"
    #   base_url = "https://openrouter.ai/api/v1/"     → "messages"
    #
    # Without this, OpenRouter would receive POST /api/v1/v1/messages → 404
    # (HTML error page), which bubbles up as the infamous
    # "Invalid API endpoint or server error (received HTML instead of JSON)".
    private def anthropic_messages_path
      base = @base_url.to_s.chomp("/")
      base.end_with?("/v1") ? "messages" : "v1/messages"
    end

    # ── Error handling ────────────────────────────────────────────────────────

    def handle_test_response(response)
      return { success: true, status: response.status } if response.status == 200

      error_body = JSON.parse(response.body) rescue nil
      {
        success: false,
        status:  response.status,
        error:   extract_error_message(error_body, response.body)
      }
    end

    def raise_error(response)
      error_body    = JSON.parse(response.body) rescue nil
      error_message = extract_error_message(error_body, response.body)
      error_code    = extract_error_code(error_body)

      Clacky::Logger.warn("client.raise_error",
        status: response.status,
        body: response.body.to_s[0, 2000],
        error_message: error_message.to_s[0, 500],
        error_code: error_code
      )

      if error_code == "insufficient_credit" || response.status == 402
        raise InsufficientCreditError.new(
          "[LLM] Insufficient credit: #{error_message}",
          error_code: "insufficient_credit",
          provider_id: @provider_id
        )
      end

      case response.status
      when 400
        # Well-behaved APIs (Anthropic, OpenAI) never put quota/availability issues in 400.
        # However, some proxy/relay providers do — so we inspect the message first.
        # Also, Bedrock returns ThrottlingException as 400 instead of 429.
        if error_message.match?(/ThrottlingException|unavailable|quota/i)
          hint = error_message.match?(/quota/i) ? " (possibly out of credits)" : ""
          raise RetryableError, "[LLM] Rate limit or service issue: #{error_message}#{hint}"
        end

        # True bad request — our message was malformed. Roll back history so the
        # broken message is not replayed on the next user turn.
        raise BadRequestError, "[LLM] Client request error: #{error_message}"
      when 401 then raise AgentError, "[LLM] Invalid API key"
      when 403 then raise AgentError, "[LLM] Access denied: #{error_message}"
      when 404 then raise AgentError, "[LLM] API endpoint not found: #{error_message}"
      when 429 then raise RetryableError, "[LLM] Rate limit exceeded, please wait a moment"
      when 500..599 then raise RetryableError, "[LLM] Service temporarily unavailable (#{response.status}), retrying..."
      else raise AgentError, "[LLM] Unexpected error (#{response.status}): #{error_message}"
      end
    end

    # Raise a friendly error if the response body is HTML (e.g. gateway error page returned with 200)
    def check_html_response(response)
      body = response.body.to_s.lstrip
      if body.start_with?("<!DOCTYPE", "<!doctype", "<html", "<HTML")
        raise RetryableError, "[LLM] Service temporarily unavailable (received HTML error page), retrying..."
      end
    end

    private def extract_error_code(error_body)
      return nil unless error_body.is_a?(Hash)
      err = error_body["error"]
      return err["code"] if err.is_a?(Hash) && err["code"].is_a?(String)
      nil
    end

    def extract_error_message(error_body, raw_body)
      if raw_body.is_a?(String) && raw_body.strip.start_with?("<!DOCTYPE", "<html")
        return "Invalid API endpoint or server error (received HTML instead of JSON)"
      end

      return "(empty response body)" if raw_body.to_s.strip.empty? && !error_body.is_a?(Hash)
      return raw_body unless error_body.is_a?(Hash)

      error_body["upstreamMessage"]&.then { |m| return m unless m.empty? }

      if error_body["error"].is_a?(Hash)
        upstream_msg = extract_upstream_error(error_body["error"])
        return upstream_msg if upstream_msg
      end

      error_body["message"]&.then             { |m| return m }
      error_body["error"].is_a?(String) ? error_body["error"] : (raw_body.to_s[0..200] + (raw_body.to_s.length > 200 ? "..." : ""))
    end

    # OpenRouter nests the real provider error inside metadata.raw as a JSON string.
    private def extract_upstream_error(error_hash)
      raw = error_hash.dig("metadata", "raw")
      if raw.is_a?(String) && !raw.empty?
        nested = JSON.parse(raw) rescue nil
        if nested.is_a?(Hash)
          details = nested.dig("error", "details")
          if details.is_a?(String) && !details.empty?
            innermost = JSON.parse(details) rescue nil
            if innermost.is_a?(Hash) && innermost.dig("error", "message")
              return innermost.dig("error", "message")
            end
          end
          return nested.dig("error", "message") if nested.dig("error", "message")
        end
      end
      error_hash["message"]
    end

    # Parse JSON with user-friendly error messages.
    # @param json_string [String] the JSON string to parse
    # @param context [String] a description of what's being parsed (e.g., "LLM response")
    # @return [Hash, Array] the parsed JSON
    # @raise [RetryableError] if parsing fails (indicates a malformed LLM response)
    def safe_json_parse(json_string, context: "response")
      JSON.parse(json_string)
    rescue JSON::ParserError => e
      # Transform technical JSON parsing errors into user-friendly messages.
      # These are usually caused by:
      #   1. Incomplete/truncated LLM response (network issue, timeout)
      #   2. LLM service returned malformed data
      #   3. Proxy/gateway corruption
      error_detail = if json_string.to_s.strip.empty?
        "received empty response"
      elsif json_string.to_s.bytesize > 500
        "response was truncated or malformed (#{json_string.to_s.bytesize} bytes received)"
      else
        "response format is invalid"
      end

      raise RetryableError, "[LLM] Failed to parse #{context}: #{error_detail}. " \
                           "This usually means the AI service returned incomplete or corrupted data. " \
                           "The request will be retried automatically."
    end

    # ── Streaming helpers ─────────────────────────────────────────────────────

    # Invoke the user's on_chunk callback in a way that never lets a callback
    # error tear down the LLM request. Streaming chunks are best-effort UI
    # updates; a buggy progress renderer must not abort an in-flight call.
    private def safe_invoke_on_chunk(on_chunk, **kwargs)
      return unless on_chunk
      on_chunk.call(**kwargs)
    rescue => e
      Clacky::Logger.warn("[on_chunk] callback raised #{e.class}: #{e.message}")
    end

    # ── Utilities ─────────────────────────────────────────────────────────────

    def deep_clone(obj)
      case obj
      when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_clone(v) }
      when Array then obj.map { |item| deep_clone(item) }
      else obj
      end
    end
  end
end
