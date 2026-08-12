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

      # Build a Responses API request body from canonical messages.
      #
      # @param messages [Array<Hash>] canonical messages (OpenAI chat format)
      # @param model    [String]
      # @param tools    [Array<Hash>] OpenAI-style tool definitions
      # @param max_tokens [Integer]
      # @param caching_enabled [Boolean] (cache_control markers on messages)
      # @param vision_supported [Boolean] whether the target model accepts images
      # @param reasoning_effort [String, nil] reasoning effort level
      # @return [Hash] Responses API request body
      def build_request_body(messages, model, tools, max_tokens, caching_enabled, vision_supported: true, reasoning_effort: nil)
        input_items = messages.flat_map { |msg| convert_message_to_input_items(msg, vision_supported: vision_supported) }

        body = {
          model:             model,
          input:             input_items,
          max_output_tokens: max_tokens
        }

        if tools&.any?
          converted = convert_tools_to_responses_format(tools)
          if caching_enabled
            converted[-1][:cache_control] = { type: "ephemeral" }
          end
          body[:tools] = converted
        end

        apply_reasoning_params(body, model, reasoning_effort)

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

        # Build the message item
        content = msg[:content]
        message_item = {
          type:    "message",
          role:    api_role,
          content: normalize_content(content, vision_supported: vision_supported)
        }
        items << message_item

        # If the assistant message has tool_calls, emit separate function_call items
        if role == "assistant" && msg[:tool_calls]
          msg[:tool_calls].each do |tc|
            items << {
              type:      "function_call",
              call_id:   tc[:id],
              name:      tc[:name],
              arguments: tc[:arguments].to_s
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
        return content unless content.is_a?(Array)

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

          result = { type: "input_text", text: text }
          result[:cache_control] = block[:cache_control] if block[:cache_control]
          result
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
      # Looks for message-type items with reasoning content blocks.
      #
      # @param output [Array<Hash>] response output items
      # @return [String, nil]
      private_class_method def self.extract_reasoning(output)
        texts = []

        output.each do |item|
          next unless item["type"] == "message"

          content = item["content"]
          next unless content.is_a?(Array)

          content.each do |block|
            case block["type"]
            when "reasoning"
              texts << block["summary"].to_s if block["summary"]
            when "output_text"
              # reasoning text might come as output_text with a "summary" attribute
            end
          end
        end

        texts.empty? ? nil : texts.join
      end

      # Extract function calls from output items.
      # Converts Responses API function_call items to canonical tool_calls format.
      #
      # @param output [Array<Hash>] response output items
      # @return [Array<Hash>] canonical tool_calls
      private_class_method def self.extract_function_calls(output)
        output.filter_map do |item|
          next unless item["type"] == "function_call"

          {
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
        when "incomplete" then "length"
        else "stop"
        end
      end

      # Apply model-specific reasoning / thinking parameters to the request body.
      # Same logic as MessageFormat::OpenAI - the reasoning params are identical
      # across Chat Completions and Responses API for all supported providers.
      #
      # @param body [Hash] request body (modified in place)
      # @param model [String] model name
      # @param reasoning_effort [String, nil]
      private_class_method def self.apply_reasoning_params(body, model, reasoning_effort)
        effort_str = reasoning_effort.to_s

        if model.to_s.match?(/^glm-[45]/i)
          if %w[off nothink disabled].include?(effort_str)
            body[:thinking] = { type: "disabled" }
          elsif !effort_str.empty?
            glm_effort =
              case effort_str
              when "max", "xhigh" then "max"
              when "high"          then "high"
              when "medium", "low" then "high"
              else                      "max"
              end
            body[:thinking] = { type: "enabled" }
            body[:reasoning_effort] = glm_effort
          end
        elsif model.to_s.match?(/^kimi-k3/i)
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
          if %w[off nothink disabled].include?(effort_str)
            body[:thinking] = { type: "disabled" }
          elsif !effort_str.empty?
            body[:thinking] = { type: "enabled" }
          end
        elsif model.to_s.match?(/^minimax-m3$/i)
          if %w[off nothink disabled].include?(effort_str)
            body[:thinking] = { type: "disabled" }
          elsif !effort_str.empty?
            body[:thinking] = { type: "adaptive" }
          end
        elsif model.to_s.match?(/deepseek/i)
          effort = case effort_str
                   when "xhigh" then "max"
                   else effort_str
                   end
          body[:reasoning_effort] = effort unless effort.empty?
        elsif reasoning_effort && !effort_str.empty?
          body[:reasoning_effort] = effort_str
        end
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
