# frozen_string_literal: true

module Clacky
  # Simple message compressor using LLM
  #
  # Strategy: Insert a compression instruction message into the messages array,
  # then compress using LLM, and replace original messages with result.
  #
  # Usage:
  #   compressor = MessageCompressor.new(client, model: "claude-3-5-sonnet")
  #   compressed = compressor.compress(messages)
  #   # => Array of compressed messages
  #
  class MessageCompressor
    COMPRESSION_PROMPT = <<~PROMPT.freeze
      You are a message compression assistant. Your task is to compress the conversation history below.

      CRITICAL RULES:
      1. Preserve all key technical decisions and code changes
      2. Keep all error messages and their solutions
      3. Retain current work status and pending tasks
      4. Maintain all file paths and important code snippets (max 200 chars each)
      5. Return format: Pure JSON array of message objects

      COMPRESSION GUIDELINES:
      - Summarize user messages while keeping their intent clear
      - Preserve assistant messages that contain important logic or decisions
      - Keep tool calls and their essential results
      - Remove repetitive or redundant content
      - Keep conversation flow understandable

      Return ONLY a valid JSON array. No markdown, no explanation.
    PROMPT

    def initialize(client, model: nil)
      @client = client
      @model = model
    end

    # Compress messages using Insert-then-Compress strategy
    # @param messages [Array<Hash>] Original conversation messages
    # @return [Array<Hash>] Compressed messages
    def compress(messages)
      # For now, return a simple compressed summary without calling LLM
      # This can be enhanced later to actually use LLM compression
      create_simple_summary(messages)
    end

    private

    def create_simple_summary(messages)
      # Find and preserve system message
      system_msg = messages.find { |m| m[:role] == "system" }

      # Create a simple summary message
      summary_text = build_simple_summary(messages)
      summary = {
        role: "user",
        content: "[SYSTEM][COMPRESSION] #{summary_text}",
        system_injected: true,
        compression_strategy: :insert_then_compress
      }

      # Return system message + summary
      [system_msg, summary].compact
    end

    def build_simple_summary(messages)
      user_count = messages.count { |m| m[:role] == "user" }
      assistant_count = messages.count { |m| m[:role] == "assistant" }
      tool_count = messages.count { |m| m[:role] == "tool" }

      "Previous conversation: #{user_count} user messages, #{assistant_count} assistant messages, #{tool_count} tool calls."
    end

    def insert_instruction(messages)
      instruction = {
        role: "system",
        content: COMPRESSION_PROMPT,
        compression_instruction: true
      }

      [instruction] + messages
    end

    def llm_compress(messages)
      # Build content for LLM - include instruction and all messages
      content = build_compression_content(messages)

      response = @client.send_message(
        content,
        model: @model,
        max_tokens: 8192
      )

      response[:content]
    end

    def build_compression_content(messages)
      # Format messages as readable text for compression
      messages.map do |msg|
        role = msg[:role]
        content = format_content(msg[:content])
        "[#{role.upcase}] #{content}"
      end.join("\n\n")
    end

    def format_content(content)
      return content if content.is_a?(String)

      if content.is_a?(Array)
        content.map do |block|
          case block[:type]
          when "text"
            block[:text]
          when "tool_use"
            "TOOL: #{block[:name]}(#{block[:input]})"
          when "tool_result"
            "RESULT: #{block[:content]}"
          else
            block.to_s
          end
        end.join("\n")
      else
        content.to_s
      end
    end

    def parse_compressed_result(result)
      # Try to extract JSON from result
      json_content = extract_json(result)

      if json_content
        JSON.parse(json_content, symbolize_names: true)
      else
        # Fallback: return original messages if parsing fails
        []
      end
    end

    def extract_json(content)
      # Try to find JSON array in the response
      # Handle cases where LLM might add markdown formatting
      content = content.strip

      # Remove markdown code block if present
      content = content.sub(/^```json\s*/, '').sub(/\s*```$/, '')
      content = content.sub(/^```\s*/, '').sub(/\s*```$/, '')

      # Try to find array pattern
      if content.include?('[') && content.include?(']')
        # Find the first [ and last ]
        first_bracket = content.index('[')
        last_bracket = content.rindex(']')
        if first_bracket && last_bracket && last_bracket > first_bracket
          return content[first_bracket..last_bracket]
        end
      end

      # Return as-is if it looks like JSON
      content if content.start_with?('[') && content.end_with?(']')
    end
  end
end
