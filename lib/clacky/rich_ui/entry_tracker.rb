# frozen_string_literal: true

module Clacky
  module RichUI
    # Lightweight id-based entry tracker for RubyRich Transcript entries.
    #
    # Replaces the fragile @tool_ids stack with explicit id-based tracking.
    # RubyRich's AgentShell already returns stable ids from start_tool_call
    # and accepts ids on finish_tool_call / update_tool_call / remove_entry.
    # EntryTracker wraps these with a semantic API and is ready for future
    # expansion (tracking markdown blocks, thinking entries, etc.).
    class EntryTracker
      def initialize
        @tool_stack = []       # ordered tool_call ids (push on start, pop on finish/error)
        @entries = {}          # id => { type:, ... } for future cross-type tracking
      end

      # Record a newly started tool call.
      # Returns the id for chaining convenience.
      def register_tool(id)
        @tool_stack << id
        @entries[id] = { type: :tool_call }
        id
      end

      # Pop and return the most recent tool_call id.
      # Returns nil when the stack is empty (tool output without a preceding call).
      def pop_tool_id
        id = @tool_stack.pop
        @entries.delete(id) if id
        id
      end

      # The most recent tool_call id without popping.
      def current_tool_id
        @tool_stack.last
      end

      # Are there any pending (unfinished) tool calls?
      def pending_tool?
        !@tool_stack.empty?
      end

      # Remove a specific entry by id.
      def remove(id)
        @entries.delete(id)
        @tool_stack.delete(id)
      end

      # Number of pending tool calls.
      def pending_count
        @tool_stack.length
      end
    end
  end
end
