# frozen_string_literal: true

require "json"
require "time"

module Clacky
  module Compression
    # Base class for all compression strategies
    #
    # Subclasses must implement:
    # - #compress(messages, options) - Main compression method
    # - #strategy_name - Unique identifier for the strategy
    #
    # Optional overrides:
    # - #setup(options) - Initialize strategy with options
    # - #teardown - Cleanup after compression
    #
    class Base
      attr_reader :strategy_name, :compression_count, :options

      def initialize(options = {})
        @options = options
        @compression_count = 0
        @initialized = false
      end

      # Main compression method - must be implemented by subclasses
      # @param messages [Array<Hash>] Array of message objects
      # @param options [Hash] Additional compression options
      # @return [Array<Hash>] Compressed messages
      def compress(messages, options = {})
        raise NotImplementedError, "#{self.class} must implement #compress"
      end

      # Get unique strategy identifier
      # @return [Symbol]
      def strategy_name
        raise NotImplementedError, "#{self.class} must implement #strategy_name"
      end

      # Initialize strategy before compression
      # @param options [Hash] Configuration options
      def setup(options = {})
        @options = options
        @initialized = true
      end

      # Cleanup after compression
      def teardown; end

      # Check if strategy is initialized
      def initialized?
        @initialized
      end

      # Get compression statistics
      # @return [Hash]
      def stats
        {
          strategy: strategy_name,
          total_compressions: @compression_count,
          initialized: @initialized
        }
      end

      # Reset strategy state
      def reset
        @compression_count = 0
        @initialized = false
      end

      # Increment compression counter
      def increment_count
        @compression_count += 1
      end

      # Estimate token count for content
      # @param content [String, Array, Hash] Message content
      # @return [Integer] Estimated token count
      def estimate_tokens(content)
        return 0 if content.nil?

        text = case content
        when String
          content
        when Array
          content.map { |c| c[:text] if c.is_a?(Hash) }.compact.join
        when Hash
          content[:text].to_s
        else
          content.to_s
        end

        return 0 if text.empty?

        # Detect language mix
        ascii_count = text.bytes.count { |b| b < 128 }
        total_bytes = text.bytes.length
        mix_ratio = total_bytes > 0 ? ascii_count.to_f / total_bytes : 1.0

        # English: ~4 chars/token, Chinese: ~2 chars/token
        base_chars_per_token = mix_ratio * 4 + (1 - mix_ratio) * 2

        (text.length / base_chars_per_token).to_i + 50
      end

      # Calculate total tokens for messages
      # @param messages [Array<Hash>]
      # @return [Hash] Token breakdown by category
      def total_message_tokens(messages)
        system_tokens = 0
        user_tokens = 0
        assistant_tokens = 0
        tool_tokens = 0

        messages.each do |msg|
          tokens = estimate_tokens(msg[:content])
          case msg[:role]
          when "system"
            system_tokens += tokens
          when "user"
            user_tokens += tokens
          when "assistant"
            assistant_tokens += tokens
          when "tool"
            tool_tokens += tokens
          end
        end

        {
          total: system_tokens + user_tokens + assistant_tokens + tool_tokens,
          system: system_tokens,
          user: user_tokens,
          assistant: assistant_tokens,
          tool: tool_tokens
        }
      end

      # Parse file action from tool result
      # @param content [String] Tool result content
      # @param action [Symbol] :created or :modified
      # @return [String, nil] File path or nil
      def parse_file_action(content, action)
        return nil unless content.is_a?(String)

        case action
        when :created
          content[/Created:\s*(.+)/, 1]&.strip
        when :modified
          content[/Updated:\s*(.+)/, 1]&.strip || content[/modified:\s*(.+)/, 1]&.strip
        else
          nil
        end
      end

      # Parse completed task from todo result
      # @param content [String] Tool result content
      # @return [String, nil] Task name or nil
      def parse_todo_result(content)
        return nil unless content.is_a?(String)

        if content.include?("completed")
          content[/completed[:\s]*(.+)/i, 1]&.strip || "task"
        elsif content.include?("added")
          content[/added[:\s]*(.+)/i, 1]&.strip || "task"
        else
          nil
        end
      end

      # Extract decisions from assistant messages
      # @param messages [Array<Hash>]
      # @return [Array<String>] List of decisions
      def extract_decisions(messages)
        messages
          .select { |m| m[:role] == "assistant" && m[:content].is_a?(String) }
          .select { |m| m[:content].include?("decision") || m[:content].include?("chose") }
          .map { |m| m[:content][/.{1,150}/] }
      end

      # Extract tool names from messages
      # @param messages [Array<Hash>]
      # @return [Array<String>] List of unique tool names
      def extract_tool_names(messages)
        messages
          .select { |m| m[:role] == "assistant" && m[:tool_calls] }
          .flat_map { |m| m[:tool_calls].map { |tc| tc.dig(:function, :name) } }
          .compact
          .uniq
      end

      # Find in-progress work from tool messages
      # @param messages [Array<Hash>]
      # @return [String, nil] In-progress description
      def find_in_progress(messages)
        messages
          .reverse
          .select { |m| m[:role] == "tool" && m[:content].is_a?(String) }
          .find { |m| m[:content].include?("in progress") || m[:content].include?("working on") }
          &.yield_self { |m| m[:content][/TODO[:\s]*(.+)/, 1]&.strip || m[:content] }
      end

      # Extract errors from tool messages
      # @param messages [Array<Hash>]
      # @return [Array<String>] List of error messages
      def extract_errors(messages)
        messages
          .select { |m| m[:role] == "tool" && m[:content].is_a?(String) }
          .select { |m| m[:content].include?("error") || m[:content].include?("failed") }
          .map { |m| m[:content][0..100] }
      end

      # Build empty extraction data structure
      # @return [Hash]
      def empty_extraction_data
        {
          user_msgs: 0,
          assistant_msgs: 0,
          tool_msgs: 0,
          tools_used: [],
          files_created: [],
          files_modified: [],
          decisions: [],
          completed_tasks: [],
          in_progress: nil,
          errors: []
        }
      end
    end
  end
end
