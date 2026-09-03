# frozen_string_literal: true

module Clacky
  module MessageFormat
    # Static helpers for the OpenAI Responses API (/v1/responses).
    #
    # The Responses API uses a different request/response shape than the
    # classic Chat Completions API:
    #
    #   - Request:  `input` array of typed items (not `messages`)
    #   - Response: `output` array of typed items (not `choices[].message`)
    #   - Token limit field: `max_output_tokens` (not `max_tokens`)
    #   - Tool calls are standalone `function_call` output items
    #   - Tool results are `function_call_output` input items
    #   - Usage: `input_tokens` / `output_tokens` (not `prompt_tokens` / `completion_tokens`)
    #
    # This module converts between the canonical internal format (which is
    # Chat Completions-shaped) and the Responses API shape.
    module OpenAIResponses
      module_function

      # ── Request building ──────────────────────────────────────────────────────

      # Build a Responses API request body from canonical messages.
      #
      # @param messages [Array<Hash>] canonical messages (OpenAI chat format)
      # @param model    [String]
      # @param tools    [Array<Hash>] OpenAI-style tool definitions
      # @param max_tokens [Integer]
      # @param caching_enabled [Boolean] kept for signature compatibility; the
      #   Responses API has no content-level cache_control field, so Clacky's
      #   cache markers are intentionally not applied on this path
      # @param vision_supported [Boolean] whether the target model accepts images
      # @param reasoning_effort [String, nil] reasoning effort level
      # @return [Hash] Responses API request body
      def build_request_body(messages, model, tools, max_tokens, _caching_enabled, vision_supported: true, reasoning_effort: nil)
        input_items = messages.flat_map { |msg| convert_message_to_input_items(msg, vision_supported: vision_supported) }

        body = {
          model:             model,
          input:             input_items,
          max_output_tokens: max_tokens
        }

        if tools&.any?
          # No cache_control markers here: the Responses API has no
          # content-level cache_control field (that is Anthropic syntax).
          # OpenAI's Responses prompt caching is automatic server-side;
          # the request-level prompt_cache_key is a routing hint that does
          # not map to Clacky's breakpoint convention. caching_enabled is
          # kept in the signature for compatibility but intentionally
          # unused on this path.
          body[:tools] = convert_tools_to_responses_format(tools)
        end

        OpenAI.apply_reasoning_params(body, model, reasoning_effort)

        body
      end

      # ── Canonical message -> Responses API input items ────────────────────────

      # Convert a single canonical message into one or more Responses API
      # input items.
      #
      # System messages become {type:"message", role:"developer"} items.
      # Assistant messages with tool_calls are split into a message item
      # plus separate function_call items.
      # Tool result messages become function_call_output items.
      #
      # @param msg [Hash] canonical message
      # @param vision_supported [Boolean]
      # @return [Array<Hash>] Responses API input items
      def convert_message_to_input_items(msg, vision_supported:)
        role = msg[:role].to_s

        # Tool result message -> function_call_output item
        if role == "tool" && msg[:tool_call_id]
          content = msg[:content]
          content = JSON.generate(content) if content.is_a?(Array) || content.is_a?(Hash)
          return [{
            type:    "function_call_output",
            call_id: msg[:tool_call_id],
            output:  content.to_s
          }]
        end

        items = []

        # Map system -> developer (Responses API convention; "system" also works
        # but "developer" is the documented role).
        api_role = role == "system" ? "developer" : role

        # Build the message item (skip when assistant message has no text
        # content but only tool_calls - the Responses API rejects null content)
        content = msg[:content]
        has_content = content && !(content.is_a?(String) && content.empty?) &&
                      !(content.is_a?(Array) && content.empty?)

        if has_content || role != "assistant"
          items << {
            type:    "message",
            role:    api_role,
            content: normalize_content(content, vision_supported: vision_supported)
          }
        end

        # If the assistant message has tool_calls, emit separate function_call items
        if role == "assistant" && msg[:tool_calls]
          msg[:tool_calls].each do |tc|
            func = tc[:function] || tc  # Handle both nested and flat formats
            items << {
              type:      "function_call",
              call_id:   tc[:id],
              name:      func[:name],
              arguments: serialize_arguments(func[:arguments])
            }
          end
        end

        items
      end

      # Normalize canonical content to Responses API content format.
      #
      # String content passes through as-is.
      # Array content: text blocks -> input_text, image_url -> input_image
      # (non-vision models get a text placeholder for images).
      #
      # @param content [String, Array, nil]
      # @param vision_supported [Boolean]
      # @return [String, Array]
      def normalize_content(content, vision_supported:)
        return content.to_s unless content.is_a?(Array)

        blocks = content.map { |b| normalize_block(b, vision_supported: vision_supported) }.compact
        blocks = [{ type: "input_text", text: "..." }] if blocks.empty?
        blocks
      end

      # Normalize a single content block for the Responses API input side.
      #
      # @param block [Hash] canonical content block
      # @param vision_supported [Boolean]
      # @return [Hash, nil]
      def normalize_block(block, vision_supported:)
        return block unless block.is_a?(Hash)

        case block[:type]
        when "text"
          text = block[:text]
          return nil if text.nil? || text.empty?

          # Any cache_control marker (Anthropic syntax) is dropped here:
          # the Responses API does not recognize content-level cache_control.
          { type: "input_text", text: text }
        when "image_url"
          if vision_supported
            # Responses API uses input_image with image_url sub-field
            { type: "input_image", image_url: block[:image_url] }
          else
            { type: "input_text", text: "[Image content removed - current model does not support vision input]" }
          end
        else
          block
        end
      end

      # ── Response parsing ──────────────────────────────────────────────────────

      # Parse a Responses API response into canonical internal format.
      #
      # @param data [Hash] parsed JSON response body
      # @return [Hash] canonical response: { content, tool_calls, finish_reason, usage, raw_api_usage }
      def parse_response(data)
        output = data["output"] || []

        # Extract text content from message-type output items
        text_content = extract_output_text(output)

        # Extract function calls from function_call-type output items
        tool_calls = extract_function_calls(output)

        # Parse usage (field names differ from Chat Completions)
        usage = data["usage"] || {}
        raw_api_usage = usage.dup

        usage_data = {
          prompt_tokens:     usage["input_tokens"],
          completion_tokens: usage["output_tokens"],
          total_tokens:      usage["total_tokens"] || (usage["input_tokens"].to_i + usage["output_tokens"].to_i)
        }

        # Responses API stores cache info under input_tokens_details
        if (details = usage["input_tokens_details"])
          usage_data[:cache_read_input_tokens]     = details["cached_tokens"]    if details["cached_tokens"].to_i > 0
          usage_data[:cache_creation_input_tokens] = details["cache_write_tokens"] if details["cache_write_tokens"].to_i > 0
        end

        # OpenRouter may also send output_tokens_details
        if (out_details = usage["output_tokens_details"])
          usage_data[:reasoning_tokens] = out_details["reasoning_tokens"] if out_details["reasoning_tokens"].to_i > 0
        end

        usage_data[:api_cost] = usage["cost"] if usage["cost"]

        # Determine finish_reason from status + output content
        finish_reason = determine_finish_reason(data, tool_calls)

        result = {
          content:       text_content,
          tool_calls:    tool_calls.empty? ? nil : tool_calls,
          finish_reason: finish_reason,
          usage:         usage_data,
          raw_api_usage: raw_api_usage
        }

        # Preserve reasoning content if present in the output
        reasoning = extract_reasoning(output)
        result[:reasoning_content] = reasoning if reasoning

        result
      end

      # ── Tool result formatting ────────────────────────────────────────────────

      # Format tool results into canonical messages to append to @messages.
      # Returns canonical format (role: "tool") - conversion to Responses API
      # function_call_output items happens inside convert_message_to_input_items
      # on the next request.
      #
      # @param response [Hash] canonical response from parse_response
      # @param tool_results [Array<Hash>] tool execution results
      # @return [Array<Hash>] canonical tool messages
      def format_tool_results(response, tool_results)
        results_map = tool_results.each_with_object({}) { |r, h| h[r[:id]] = r }

        response[:tool_calls].map do |tc|
          result = results_map[tc[:id]]
          raw_content = result ? result[:content] : { error: "Tool result missing" }.to_json

          content = raw_content.is_a?(Array) ? JSON.generate(raw_content) : raw_content

          {
            role:         "tool",
            tool_call_id: tc[:id],
            content:      content
          }
        end
      end

      # ── Private helpers ───────────────────────────────────────────────────────

      # The Responses API expects function_call arguments as a JSON *string*.
      # Canonical tool_calls normally carry a JSON string already, but a Hash
      # or Array value must be JSON-encoded — #to_s would emit a Ruby literal
      # (e.g. {:city=>"Tokyo"}) that the tool side cannot parse.
      private_class_method def self.serialize_arguments(arguments)
        return JSON.generate(arguments) if arguments.is_a?(Hash) || arguments.is_a?(Array)

        arguments.to_s
      end

      # Extract text content from output items.
      # Looks for message-type items with output_text content blocks.
      #
      # @param output [Array<Hash>] response output items
      # @return [String, nil]
      private_class_method def self.extract_output_text(output)
        texts = []

        output.each do |item|
          next unless item["type"] == "message"

          content = item["content"]
          next unless content.is_a?(Array)

          content.each do |block|
            next unless block["type"] == "output_text"
            texts << block["text"].to_s
          end
        end

        texts.empty? ? nil : texts.join
      end

      # Extract reasoning content from output items.
      # Supports both shapes seen in the wild:
      #   1. OpenAI official — a "reasoning" block inside a message item,
      #      with summary[] and/or content[] of reasoning_text blocks.
      #   2. DeepSeek — a top-level "reasoning" item whose content array
      #      carries {"type":"reasoning_text","text":...} blocks.
      # Prefers full reasoning text (reasoning_text blocks); falls back to
      # summary text when only a summary is present.
      #
      # @param output [Array<Hash>] response output items
      # @return [String, nil]
      private_class_method def self.extract_reasoning(output)
        texts = []

        output.each do |item|
          content = item["content"]

          case item["type"]
          when "reasoning"
            next unless content.is_a?(Array)
            before = texts.length
            collect_reasoning_texts(content, texts)
            collect_summary_texts(content, texts) if texts.length == before
          when "message"
            next unless content.is_a?(Array)
            content.each do |block|
              case block["type"]
              when "reasoning"
                before = texts.length
                collect_reasoning_texts(block["content"], texts)
                collect_summary_texts(block["summary"], texts) if texts.length == before
              when "output_text"
                # Some providers surface reasoning as output_text blocks
                # carrying a summary attribute.
                collect_summary_texts(block["summary"], texts)
              end
            end
          end
        end

        texts.empty? ? nil : texts.join
      end

      private_class_method def self.collect_reasoning_texts(blocks, texts)
        return unless blocks.is_a?(Array)
        blocks.each do |b|
          texts << b["text"].to_s if b.is_a?(Hash) && b["type"] == "reasoning_text" && b["text"]
        end
      end

      private_class_method def self.collect_summary_texts(summary, texts)
        return unless summary.is_a?(Array)
        summary.each do |b|
          texts << b["text"].to_s if b.is_a?(Hash) && b["type"] == "summary_text" && b["text"]
        end
      end

      # Extract function calls from output items.
      # Converts Responses API function_call items to canonical tool_calls format.
      #
      # @param output [Array<Hash>] response output items
      # @return [Array<Hash>] canonical tool_calls
      private_class_method def self.extract_function_calls(output)
        # each_with_object instead of filter_map to stay Ruby 2.6 compatible.
        output.each_with_object([]) do |item, calls|
          next unless item["type"] == "function_call"

          calls << {
            id:       item["call_id"],
            type:     "function",
            name:     item["name"],
            arguments: item["arguments"].to_s
          }
        end
      end

      # Determine the canonical finish_reason from Responses API status + output.
      #
      # @param data [Hash] full response body
      # @param tool_calls [Array<Hash>] extracted tool calls
      # @return [String]
      private_class_method def self.determine_finish_reason(data, tool_calls)
        # If there are tool calls, the model wants to call tools
        return "tool_calls" unless tool_calls.empty?

        status = data["status"]
        case status
        when "completed"  then "stop"
        when "incomplete" then incomplete_finish_reason(data)
        else "stop"
        end
      end

      # Map an "incomplete" response to a canonical finish_reason via
      # incomplete_details.reason: "content_filter" means the response was
      # blocked by safety filtering (typically empty) and must not be
      # mislabelled as a mere token limit ("length").
      #
      # @param data [Hash] full response body
      # @return [String]
      private_class_method def self.incomplete_finish_reason(data)
        reason = data.dig("incomplete_details", "reason")
        reason == "content_filter" ? "content_filter" : "length"
      end
      # Convert Chat Completions tool definitions to Responses API format.
      # Chat Completions: {type: "function", function: {name:, description:, parameters:}}
      # Responses API:    {type: "function", name:, description:, parameters:}
      # Tools already in flat format (no "function" key) pass through unchanged.
      private_class_method def self.convert_tools_to_responses_format(tools)
        tools.map do |tool|
          func = tool[:function] || tool["function"]
          next tool unless func.is_a?(Hash)
          {
            type:        tool[:type] || tool["type"] || "function",
            name:        func[:name] || func["name"],
            description: func[:description] || func["description"],
            parameters:  func[:parameters] || func["parameters"]
          }
        end
      end
    end
  end
end
