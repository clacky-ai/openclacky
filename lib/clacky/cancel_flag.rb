# frozen_string_literal: true

module Clacky
  # A one-way, thread-safe cancellation flag shared across a parent agent and
  # the subagents it forks. Fan-out runs each subagent on its own worker thread;
  # when the parent is interrupted the worker threads must learn to stop, but
  # they cannot see the parent's thread-local task epoch. Flipping this flag is
  # the shared signal every subagent polls at its safe checkpoints.
  class CancelFlag
    def initialize
      @mutex = Mutex.new
      @cancelled = false
    end

    def cancel!
      @mutex.synchronize { @cancelled = true }
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end
  end
end
