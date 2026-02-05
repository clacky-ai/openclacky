# frozen_string_literal: true

module Clacky
  # Message compressor using LLM-based compression
  #
  # Strategy: Uses LLM to intelligently compress conversation history while preserving
  # critical information like technical decisions, code changes, error messages, and
  # pending tasks. The compression prompt instructs the LLM to return a JSON array
  # of compressed messages.
  #
  # Usage:
  #   compressor = MessageCompressor.new(client, model: "claude-3-5-sonnet")
  #   compressed = compressor.compress(messages)
  #   # => Array of compressed messages (system message + compressed conversation)
  #
  # The compress method:
  # 1. Preserves the system message
  # 2. Formats all other messages as readable text
  # 3. Sends to LLM with compression instructions
  # 4. Parses the JSON response back into message objects
  # 5. Returns [system_message, *compressed_messages]
  #
  class MessageCompressor
    COMPRESSION_PROMPT = <<~PROMPT.freeze
      ═══════════════════════════════════════════════════════════════
      CRITICAL: TASK CHANGE - MEMORY COMPRESSION MODE
      ═══════════════════════════════════════════════════════════════
      The conversation above has ENDED. You are now in MEMORY COMPRESSION MODE.

      CRITICAL INSTRUCTIONS - READ CAREFULLY:

      1. This is NOT a continuation of the conversation
      2. DO NOT respond to any requests in the conversation above
      3. DO NOT call ANY tools or functions
      4. DO NOT use tool_calls in your response
      5. Your response MUST be PURE TEXT ONLY

      YOUR ONLY TASK: Create a comprehensive summary of the conversation above.

      REQUIRED RESPONSE FORMAT:
      Your response MUST start with <analysis> or <summary> tags. No other format is acceptable.

      Follow the detailed compression prompt structure provided earlier. Focus on:
      - User's explicit requests and intents
      - Key technical concepts and code changes
      - Files examined and modified
      - Errors encountered and fixes applied
      - Current work status and pending tasks

      Begin your summary NOW. Remember: PURE TEXT response only, starting with <analysis> or <summary> tags."""
    PROMPT

    def initialize(client, model: nil)
      @client = client
      @model = model
    end

    # Compress messages using Insert-then-Compress strategy with LLM
    # @param messages [Array<Hash>] Original conversation messages
    # @param recent_messages [Array<Hash>] Recent messages to keep uncompressed (optional)
    # @return [Array<Hash>] Compressed messages
    def compress(messages, recent_messages: [])
      # Use LLM-based compression
      llm_compress_messages(messages, recent_messages: recent_messages)
    end

    private

    # Main LLM compression method
    def llm_compress_messages(messages, recent_messages: [])
      # Find and preserve system message
      system_msg = messages.find { |m| m[:role] == "system" }

      # Get messages to compress (exclude system message and recent messages)
      messages_to_compress = messages.reject { |m| m[:role] == "system" || recent_messages.include?(m) }

      # If nothing to compress, return original messages
      return messages if messages_to_compress.empty?

      # Build compression prompt with instruction and conversation
      content = build_compression_content(messages_to_compress)
      full_prompt = "#{COMPRESSION_PROMPT}\n\nConversation to compress:\n\n#{content}"

      # Prepare messages array for LLM call
      llm_messages = [{ role: "user", content: full_prompt }]

      # Call LLM to compress
      response = @client.send_messages(
        llm_messages,
        model: @model,
        max_tokens: 8192
      )

      # Parse the compressed result
      compressed_content = response[:content]
      parsed_messages = parse_compressed_result(compressed_content)

      # If parsing fails or returns empty, raise error
      if parsed_messages.nil? || parsed_messages.empty?
        raise "LLM compression failed: unable to parse compressed messages"
      end

      # Return system message + compressed messages + recent messages
      [system_msg, *parsed_messages, *recent_messages].compact
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
      # Return the compressed result as a single assistant message
      # Keep the <analysis> or <summary> tags as they provide semantic context
      content = result.strip

      if content.empty?
        []
      else
        [{ role: "assistant", content: content }]
      end
    end
  end
end
