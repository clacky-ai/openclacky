# frozen_string_literal: true

module Clacky
  module MessageFormat
    # Static helpers for OpenAI-compatible API message format.
    #
    # The canonical internal @messages format IS OpenAI format, so this module
    # mainly handles response parsing, tool result formatting, and message
    # type identification — minimal transformation needed.
    module OpenAI
      module_function

      # ── Message type identification ───────────────────────────────────────────

      # Returns true if the message is a canonical tool result.
      def tool_result_message?(msg)
        msg[:role] == "tool" && !msg[:tool_call_id].nil?
      end

      # Returns the tool_call_ids referenced in a tool result message.
      def tool_call_ids(msg)
        return [] unless tool_result_message?(msg)

        [msg[:tool_call_id]]
      end

      # ── Request building ──────────────────────────────────────────────────────

      # Build an OpenAI-compatible request body.
      #
      # Messages go through the canonical→OpenAI conversion layer
      # (normalize_messages). For most models this is identity because
      # the internal canonical format IS OpenAI format. The conversion
      # handles one edge case: image_url content blocks are stripped
      # when vision_supported is false (e.g. DeepSeek, Kimi, MiniMax),
      # replacing them with a text placeholder so the API doesn't reject
      # the request with "unknown variant 'image_url'".
      #
      # @param messages [Array<Hash>] canonical messages
      # @param model    [String]
      # @param tools    [Array<Hash>] OpenAI-style tool definitions
      # @param max_tokens [Integer]
      # @param caching_enabled [Boolean] (only effective for Claude via OpenRouter)
      # @param vision_supported [Boolean] whether the target model accepts
      #   image_url content blocks (default true, conservative)
      # @return [Hash]
      def build_request_body(messages, model, tools, max_tokens, caching_enabled, vision_supported: true, reasoning_effort: nil)
        api_messages = messages.map { |msg| normalize_message_content(msg, vision_supported: vision_supported) }

        body = { model: model, token_field_for(model) => max_tokens, messages: api_messages }

        if tools&.any?
          if caching_enabled
            cached_tools = deep_clone(tools)
            cached_tools.last[:cache_control] = { type: "ephemeral" }
            body[:tools] = cached_tools
          else
            body[:tools] = tools
          end
        end

        apply_reasoning_params(body, model, reasoning_effort)

        body
      end

      # ── Canonical → OpenAI conversion ─────────────────────────────────────────

      # Process a single message's content through the canonical→OpenAI
      # conversion layer. For String content this is a no-op; for Array
      # content each block goes through normalize_block.
      #
      # @param msg [Hash] canonical message
      # @param vision_supported [Boolean]
      # @return [Hash] message with content normalised for OpenAI API
      def normalize_message_content(msg, vision_supported:)
        content = msg[:content]
        return msg unless content.is_a?(Array)

        blocks = content_to_blocks(content, vision_supported: vision_supported)
        # Most APIs reject empty content arrays — use a placeholder text block.
        blocks = [{ type: "text", text: "..." }] if blocks.empty?
        msg.merge(content: blocks)
      end

      # Convert canonical content array to OpenAI-compatible block array.
      # Each block goes through normalize_block; nil results are compacted.
      #
      # @param content [Array<Hash>] canonical content blocks
      # @param vision_supported [Boolean]
      # @return [Array<Hash>]
      def content_to_blocks(content, vision_supported:)
        content.map { |b| normalize_block(b, vision_supported: vision_supported) }.compact
      end

      # Normalize a single canonical content block to OpenAI API format.
      #
      # Canonical text blocks pass through (with cache_control preserved).
      # image_url blocks are kept for vision-capable models and replaced
      # with a text placeholder for non-vision models (DeepSeek, Kimi, etc.).
      #
      # @param block [Hash] canonical content block
      # @param vision_supported [Boolean]
      # @return [Hash, nil] nil for empty-text blocks (dropped)
      def normalize_block(block, vision_supported:)
        return block unless block.is_a?(Hash)

        case block[:type]
        when "text"
          # Drop empty text blocks — most APIs (Anthropic, DeepSeek, etc.)
          # reject { type: "text", text: "" }.
          text = block[:text]
          return nil if text.nil? || text.empty?

          result = { type: "text", text: text }
          result[:cache_control] = block[:cache_control] if block[:cache_control]
          result
        when "image_url"
          if vision_supported
            block  # Pass through — GPT-4V, Gemini, etc. accept image_url
          else
            # Replace with text placeholder so the API doesn't reject the
            # request. The model will still see the context that an image
            # was present (from file_prompt / system_injected metadata).
            { type: "text", text: "[Image content removed — current model does not support vision input]" }
          end
        else
          block  # Pass through unknown block types (tool_use, tool_result, etc.)
        end
      end

      # ── Response parsing ──────────────────────────────────────────────────────

      # Parse OpenAI-compatible API response into canonical internal format.
      # @param data [Hash] parsed JSON response body
      # @return [Hash]
      def parse_response(data)
        message       = data["choices"].first["message"]
        usage         = data["usage"] || {}
        raw_api_usage = usage.dup

        usage_data = {
          prompt_tokens:     usage["prompt_tokens"],
          completion_tokens: usage["completion_tokens"],
          total_tokens:      usage["total_tokens"]
        }

        usage_data[:api_cost]                    = usage["cost"]                            if usage["cost"]
        usage_data[:cache_creation_input_tokens] = usage["cache_creation_input_tokens"]     if usage["cache_creation_input_tokens"]
        usage_data[:cache_read_input_tokens]     = usage["cache_read_input_tokens"]         if usage["cache_read_input_tokens"]

        # OpenRouter stores cache info under prompt_tokens_details
        if (details = usage["prompt_tokens_details"])
          usage_data[:cache_read_input_tokens]     = details["cached_tokens"]    if details["cached_tokens"].to_i > 0
          usage_data[:cache_creation_input_tokens] = details["cache_write_tokens"] if details["cache_write_tokens"].to_i > 0
        end

        result = {
          content:       message["content"],
          tool_calls:    parse_tool_calls(message["tool_calls"]),
          finish_reason: data["choices"].first["finish_reason"],
          usage:         usage_data,
          raw_api_usage: raw_api_usage
        }

        # Preserve reasoning_content (e.g. Kimi/Moonshot extended thinking)
        result[:reasoning_content] = message["reasoning_content"] if message["reasoning_content"]

        result
      end

      # ── Tool result formatting ────────────────────────────────────────────────

      # Format tool results into canonical messages to append to @messages.
      # @return [Array<Hash>] canonical tool messages
      def format_tool_results(response, tool_results)
        results_map = tool_results.each_with_object({}) { |r, h| h[r[:id]] = r }

        response[:tool_calls].map do |tc|
          result = results_map[tc[:id]]
          raw_content = result ? result[:content] : { error: "Tool result missing" }.to_json

          # OpenAI tool message content must be a String.
          # If a tool returned multipart Array blocks (e.g. screenshot image), convert to JSON.
          content = raw_content.is_a?(Array) ? JSON.generate(raw_content) : raw_content

          {
            role:         "tool",
            tool_call_id: tc[:id],
            content:      content
          }
        end
      end

      # ── Private helpers ───────────────────────────────────────────────────────

      # Returns the token-limit field name for the given model.
      # Most OpenAI-compatible APIs use :max_tokens; MiMo-V2.5 (Xiaomi) and
      # MiniMax-M3 use :max_completion_tokens to cap the combined thinking +
      # answer length (M3 documents max_completion_tokens over the legacy
      # max_tokens field).
      private_class_method def self.token_field_for(model)
        if model.to_s.match?(/^mimo-v2/i) || model.to_s.match?(/^minimax-m3$/i)
          :max_completion_tokens
        else
          :max_tokens
        end
      end

      # Apply model-specific reasoning / thinking parameters to the request body.
      #
      # Different model families expose extended reasoning through different API
      # fields. We map the shared internal reasoning_effort value to each
      # family's native parameters in-place.
      #
      # Zero side-effects: when reasoning_effort is nil/empty the body is
      # unchanged, preserving the provider default for all models.
      #
      # Single source of truth for reasoning param mapping — shared with
      # MessageFormat::OpenAIResponses (the Responses API accepts the same
      # top-level fields).
      def self.apply_reasoning_params(body, model, reasoning_effort)
        effort_str = reasoning_effort.to_s

        if model.to_s.match?(/\Aglm-5[-.]3/i)
          # GLM-5.3 always thinks: thinking.type "disabled" is rejected with an
          # error (Z.ai migration guide), so "off" maps to the lightest effort
          # "low". Effort accepts low/high/max only; server default is max.
          body[:thinking] = { type: "enabled" }
          if %w[off nothink disabled].include?(effort_str)
            body[:reasoning_effort] = "low"
          elsif !effort_str.empty?
            body[:reasoning_effort] =
              case effort_str
              when "max", "xhigh"  then "max"
              when "high"          then "high"
              when "medium", "low" then "low"
              else                      "max"
              end
          end
        elsif model.to_s.match?(/^glm-[45]/i)
          # GLM (Zhipu / Z.ai) supports a native top-level "thinking" field
          # ({type: "enabled"|"disabled"}) plus a restricted reasoning_effort
          # that only accepts "max" or "high". Other effort levels collapse
          # to "high". Send both fields so GLM activates thinking correctly.
          if %w[off nothink disabled].include?(effort_str)
            body[:thinking] = { type: "disabled" }
          elsif !effort_str.empty?
            glm_effort =
              case effort_str
              when "max", "xhigh" then "max"
              when "high"          then "high"
              when "medium", "low" then "high"   # GLM collapses these to "high"
              else                      "max"
              end
            body[:thinking] = { type: "enabled" }
            body[:reasoning_effort] = glm_effort
          end
        elsif model.to_s.match?(/^kimi-k3/i)
          # Kimi K3 reasoning_effort only accepts low/high/max (default max).
          # Thinking is always enabled and cannot be turned off; "off" maps
          # to the lowest intensity "low". Unsupported effort levels (medium,
          # xhigh) would be rejected or ignored by the server.
          if %w[off nothink disabled].include?(effort_str)
            body[:reasoning_effort] = "low"
          elsif !effort_str.empty?
            body[:reasoning_effort] =
              case effort_str
              when "max", "xhigh"  then "max"
              when "high"          then "high"
              when "medium", "low" then "low"
              else                      "max"
              end
          end
        elsif model.to_s.match?(/^mimo-v2/i)
          # MiMo-V2.5 (Xiaomi) controls reasoning via a top-level
          # thinking:{type:...} field rather than reasoning_effort. Map the
          # internal reasoning_effort value to thinking on/off so MiMo does
          # not receive an unsupported parameter.
          if %w[off nothink disabled].include?(effort_str)
            body[:thinking] = { type: "disabled" }
          elsif !effort_str.empty?
            body[:thinking] = { type: "enabled" }
          end
        elsif model.to_s.match?(/^minimax-m3$/i)
          # MiniMax-M3 controls thinking via a top-level "thinking" field with
          # { type: "adaptive" | "disabled" } — the same envelope shape MiMo
          # uses, but with MiniMax-specific values. Adaptive thinking is the
          # server default when the field is omitted, so we only send the
          # field to explicitly switch modes:
          #   - reasoning_effort "off"/"disabled"  → thinking disabled
          #     (M3 answers directly; M2.7 keeps thinking on regardless).
          #   - any other effort                   → adaptive thinking (M3
          #     decides per request); we let the server pick the intensity.
          # M2.7 cannot disable thinking and ignores this field, so sending
          # it is harmless for the rest of the MiniMax lineup.
          if %w[off nothink disabled].include?(effort_str)
            body[:thinking] = { type: "disabled" }
          elsif !effort_str.empty?
            body[:thinking] = { type: "adaptive" }
          end
        elsif model.to_s.match?(/deepseek/i)
          # DeepSeek V4 reasoning_effort only accepts low/high/max.
          # xhigh is not recognized — map it to max.
          effort = case effort_str
                   when "xhigh" then "max"
                   else effort_str
                   end
          body[:reasoning_effort] = effort unless effort.empty?
        elsif reasoning_effort && !effort_str.empty?
          body[:reasoning_effort] = effort_str
        end
      end

      private_class_method def self.parse_tool_calls(raw)
        return nil if raw.nil? || raw.empty?

        raw.filter_map do |call|
          func = call["function"] || {}
          name = func["name"]
          arguments = func["arguments"]
          # Skip malformed tool calls where name or arguments is nil (broken API response)
          next if name.nil? || arguments.nil?

          tc = { id: call["id"], type: call["type"], name: name, arguments: arguments }
          # Vertex Gemini's OpenAI shim returns thought_signature inside
          # tool_calls[i].extra_content.google and requires it echoed back on
          # replay, otherwise the next turn 400s with "Function call is missing
          # a thought_signature". Preserve it through the canonical layer.
          tc[:extra_content] = call["extra_content"] if call["extra_content"]
          tc
        end
      end

      private_class_method def self.deep_clone(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_clone(v) }
        when Array then obj.map { |item| deep_clone(item) }
        else obj
        end
      end
    end
  end
end
