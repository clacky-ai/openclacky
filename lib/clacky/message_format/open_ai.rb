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

        body = { model: model, max_tokens: max_tokens, messages: api_messages }

        if tools&.any?
          if caching_enabled
            cached_tools = deep_clone(tools)
            cached_tools.last[:cache_control] = { type: "ephemeral" }
            body[:tools] = cached_tools
          else
            body[:tools] = tools
          end
        end

        if reasoning_effort && !reasoning_effort.to_s.empty?
          body[:reasoning_effort] = reasoning_effort.to_s
        end

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

      private_class_method def self.parse_tool_calls(raw)
        return nil if raw.nil? || raw.empty?

        raw.filter_map do |call|
          func = call["function"] || {}
          name = func["name"]
          arguments = func["arguments"]
          # Skip malformed tool calls where name or arguments is nil (broken API response)
          next if name.nil? || arguments.nil?

          { id: call["id"], type: call["type"], name: name, arguments: arguments }
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
