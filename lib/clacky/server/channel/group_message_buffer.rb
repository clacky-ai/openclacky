# frozen_string_literal: true

module Clacky
  module Channel
    # Stores recent group chat messages per chat_id so that when the bot is
    # @-mentioned it can inject prior conversation context into the agent prompt.
    # Thread-safe; bounded to MAX_MESSAGES per chat to limit memory growth.
    class GroupMessageBuffer
      MAX_MESSAGES = 15
      PROMPT_LIMIT = 5

      Entry = Struct.new(:user_id, :user_name, :text, keyword_init: true)

      def initialize
        @buffers = {}
        @mutex   = Mutex.new
      end

      # @param chat_id [String]
      # @param user_id [String]
      # @param user_name [String, nil]
      # @param text    [String]
      def push(chat_id, user_id:, text:, user_name: nil)
        return if text.nil? || text.strip.empty?

        @mutex.synchronize do
          buf = (@buffers[chat_id] ||= [])
          buf << Entry.new(user_id: user_id, user_name: user_name, text: text.strip)
          buf.shift if buf.size > MAX_MESSAGES
        end
      end

      # Return the most recent `limit` entries without clearing the buffer.
      # @param chat_id [String]
      # @param limit [Integer, nil] max entries to return; nil = all
      # @return [Array<Entry>]
      def peek(chat_id, limit: nil)
        @mutex.synchronize do
          buf = @buffers[chat_id] || []
          limit ? buf.last(limit) : buf.dup
        end
      end

      # Return buffered entries for a chat and clear them atomically.
      # Returns an empty array when there is no history.
      # @param chat_id [String]
      # @return [Array<Entry>]
      def take(chat_id)
        @mutex.synchronize { @buffers.delete(chat_id) || [] }
      end
    end
  end
end
