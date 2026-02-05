# frozen_string_literal: true

require_relative "base"

module Clacky
  module Compression
    # Standard compression strategy - preserves the original compression logic
    #
    # This strategy:
    # 1. Keeps the system message (first message)
    # 2. Keeps recent N messages (maintaining tool call/result pairs)
    # 3. Compresses all middle messages into a hierarchical summary
    #
    # Configuration options:
    # - threshold: Token count to trigger compression (default: 80_000)
    # - message_threshold: Message count to trigger compression (default: 100)
    # - target_tokens: Target size after compression (default: 70_000)
    # - max_recent: Maximum recent messages to keep (default: 30)
    #
    class Standard < Base
      STRATEGY_NAME = :standard

      # Compression thresholds
      THRESHOLD = 80_000
      MESSAGE_COUNT_THRESHOLD = 100
      TARGET_COMPRESSED_TOKENS = 70_000
      MAX_RECENT_MESSAGES = 30

      def initialize(options = {})
        super(options)
        @recent_messages = []
        @summary = nil
      end

      def strategy_name
        STRATEGY_NAME
      end

      # Main compression method
      # @param messages [Array<Hash>] All conversation messages
      # @param options [Hash] Additional options
      # @return [Array<Hash>] Compressed messages
      def compress(messages, options = {})
        increment_count

        # Calculate total tokens and message count
        token_counts = total_message_tokens(messages)
        total_tokens = token_counts[:total]
        message_count = messages.length

        # Check if compression is needed
        token_threshold_exceeded = total_tokens >= threshold(options)
        message_count_exceeded = message_count >= message_count_threshold(options)

        # Return original if no threshold exceeded
        unless token_threshold_exceeded || message_count_exceeded
          return messages.dup
        end

        # Calculate how much we need to reduce
        reduction_needed = total_tokens - target_tokens(options)

        # Skip if reduction is minimal
        if token_threshold_exceeded && reduction_needed < (total_tokens * 0.1)
          return messages.dup
        end

        # Calculate target recent count
        target_recent_count = calculate_target_recent_count(reduction_needed)

        # Find system message
        system_msg = messages.find { |m| m[:role] == "system" }

        # Get recent messages with tool pairs
        recent = get_recent_messages_with_tool_pairs(messages, target_recent_count)
        recent = [] if recent.nil?

        # Get messages to compress
        messages_to_compress = messages.reject { |m| m[:role] == "system" || recent.include?(m) }

        # Return if nothing to compress
        if messages_to_compress.empty?
          return [system_msg, *recent].compact
        end

        # Generate hierarchical summary
        summary = generate_hierarchical_summary(messages_to_compress)

        # Rebuild messages
        @recent_messages = recent
        @summary = summary

        [system_msg, summary, *recent].compact
      end

      # Compression statistics
      def stats
        super.merge(
          recent_messages_count: @recent_messages&.length || 0,
          has_summary: !@summary.nil?
        )
      end

      private

      def threshold(options)
        options[:threshold] || THRESHOLD
      end

      def message_count_threshold(options)
        options[:message_count_threshold] || MESSAGE_COUNT_THRESHOLD
      end

      def target_tokens(options)
        options[:target_tokens] || TARGET_COMPRESSED_TOKENS
      end

      def max_recent_messages(options)
        options[:max_recent] || MAX_RECENT_MESSAGES
      end

      def calculate_target_recent_count(reduction_needed)
        tokens_per_message = 500
        recent_budget = (target_tokens(@options) * 0.2).to_i
        target_messages = (recent_budget / tokens_per_message).to_i
        [[target_messages, 20].max, max_recent_messages(@options)].min
      end

      # Ensure tool calls and their results are kept together
      def get_recent_messages_with_tool_pairs(messages, count)
        return [] if messages.nil? || messages.empty?

        included = Set.new
        collected = 0
        i = messages.size - 1

        while i >= 0 && collected < count
          msg = messages[i]
          next if included.include?(i)

          included.add(i)
          collected += 1

          # If assistant with tool_calls, include all corresponding results
          if msg[:role] == "assistant" && msg[:tool_calls]
            tool_call_ids = msg[:tool_calls].map { |tc| tc[:id] }

            j = i + 1
            while j < messages.size
              next_msg = messages[j]

              if next_msg[:role] == "tool" && tool_call_ids.include?(next_msg[:tool_call_id])
                included.add(j)
              elsif next_msg[:role] != "tool"
                break
              end

              j += 1
            end
          end

          # If tool result, ensure its assistant message is included
          if msg[:role] == "tool"
            j = i - 1
            while j >= 0
              prev_msg = messages[j]

              if prev_msg[:role] == "assistant" && prev_msg[:tool_calls]
                has_match = prev_msg[:tool_calls].any? { |tc| tc[:id] == msg[:tool_call_id] }

                if has_match
                  unless included.include?(j)
                    included.add(j)
                    collected += 1
                  end

                  # Include all tool results for this assistant
                  tool_ids = prev_msg[:tool_calls].map { |tc| tc[:id] }
                  k = j + 1
                  while k < messages.size
                    if messages[k][:role] == "tool" && tool_ids.include?(messages[k][:tool_call_id])
                      included.add(k)
                    elsif messages[k][:role] != "tool"
                      break
                    end
                    k += 1
                  end

                  break
                end
              end

              j -= 1
            end
          end

          i -= 1
        end

        included.to_a.sort.map { |idx| messages[idx] }
      end

      # Generate summary with progressive levels
      def generate_hierarchical_summary(messages)
        level = @compression_count

        # Adjust level to max 4
        level = [level, 4].min

        data = extract_key_information(messages)
        summary_text = build_summary_text(data, level)

        {
          role: "user",
          content: "[SYSTEM][COMPRESSION LEVEL #{level}] #{summary_text}",
          system_injected: true,
          compression_level: level,
          compression_count: @compression_count,
          compression_strategy: :standard
        }
      end

      # Extract key info from messages
      def extract_key_information(messages)
        return empty_extraction_data if messages.nil?

        {
          user_msgs: messages.count { |m| m[:role] == "user" },
          assistant_msgs: messages.count { |m| m[:role] == "assistant" },
          tool_msgs: messages.count { |m| m[:role] == "tool" },
          tools_used: extract_tool_names(messages),
          files_created: extract_files(messages, :created),
          files_modified: extract_files(messages, :modified),
          decisions: extract_decisions(messages).first(5),
          completed_tasks: extract_completed_tasks(messages),
          in_progress: find_in_progress(messages),
          errors: extract_errors(messages)
        }
      end

      def extract_files(messages, action)
        messages
          .select { |m| m[:role] == "tool" }
          .map { |m| parse_file_action(m[:content], action) }
          .compact
      end

      def extract_completed_tasks(messages)
        messages
          .select { |m| m[:role] == "tool" && m[:content].is_a?(String) }
          .select { |m| m[:content].include?("completed") }
          .map { |m| parse_todo_result(m[:content]) }
          .compact
      end

      # Summary builders for each level
      def build_summary_text(data, level)
        case level
        when 1
          build_level1(data)
        when 2
          build_level2(data)
        when 3
          build_level3(data)
        else
          build_level4(data)
        end
      end

      def build_level1(data)
        parts = []
        parts << "Previous conversation summary (#{data[:user_msgs]} requests, #{data[:assistant_msgs]} responses, #{data[:tool_msgs]} tools):"

        if data[:files_created].any?
          parts << "Created: #{data[:files_created].map { |f| File.basename(f) }.join(', ')}"
        end

        if data[:files_modified].any?
          parts << "Modified: #{data[:files_modified].map { |f| File.basename(f) }.join(', ')}"
        end

        if data[:completed_tasks].any?
          parts << "Completed: #{data[:completed_tasks].first(3).join(', ')}"
        end

        if data[:in_progress]
          parts << "In Progress: #{data[:in_progress]}"
        end

        if data[:decisions].any?
          parts << "Decisions: #{data[:decisions].map { |d| d.gsub("\n", " ").strip }.join('; ')}"
        end

        if data[:tools_used].any?
          parts << "Tools: #{data[:tools_used].join(', ')}"
        end

        parts << "Continuing with recent conversation..."
        parts.join("\n")
      end

      def build_level2(data)
        parts = ["Conversation summary:"]

        all_files = (data[:files_created] + data[:files_modified]).uniq
        if all_files.any?
          parts << "Files: #{all_files.first(5).map { |f| File.basename(f) }.join(', ')}"
        end

        accomplishments = []
        accomplishments << "#{data[:completed_tasks].size} tasks completed" if data[:completed_tasks].any?
        accomplishments << "#{data[:tool_msgs]} tools executed" if data[:tool_msgs] > 0

        parts << accomplishments.join(', ') if accomplishments.any?
        parts << "Recent context follows..."
        parts.join("\n")
      end

      def build_level3(data)
        parts = ["Project progress:"]

        all_files = (data[:files_created] + data[:files_modified]).uniq
        parts << "#{all_files.size} files modified, #{data[:completed_tasks].size} tasks done"

        if data[:in_progress]
          parts << "Currently: #{data[:in_progress]}"
        end

        parts << "See recent messages for details."
        parts.join("\n")
      end

      def build_level4(data)
        all_files = (data[:files_created] + data[:files_modified]).uniq
        "Progress: #{data[:completed_tasks].size} tasks, #{all_files.size} files. Recent: #{data[:tools_used].last(3).uniq.join(', ')}"
      end
    end
  end
end
