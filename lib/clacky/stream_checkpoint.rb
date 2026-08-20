# frozen_string_literal: true

require "json"
require "fileutils"

module Clacky
  # Periodically checkpoints a streaming LLM response's accumulated content
  # to disk so that a mid-stream crash (SIGKILL/OOM) doesn't lose the
  # partially-generated message.
  #
  # Lifecycle:
  #   1. Created at the start of call_llm() with a session-scoped path
  #   2. Aggregator calls #update(snapshot) on every content delta
  #   3. Snapshot is flushed to disk at most every @interval seconds
  #   4. On successful completion: #clear! deletes the checkpoint file
  #   5. On crash: the file survives and is recovered by restore_session
  class StreamCheckpoint
    # @param path [String] Absolute path to the checkpoint .json file
    # @param interval [Float] Minimum seconds between disk flushes
    def initialize(path:, interval: 0.5)
      @path = path
      @interval = interval
      @last_flush = 0.0
      @pending = nil
      @first_update = true
      FileUtils.mkdir_p(File.dirname(@path))
    end

    # Called by the StreamAggregator on every content delta.
    # Stores the snapshot in memory and flushes to disk at most every
    # @interval seconds. The very first update flushes immediately so
    # even very short responses get at least one checkpoint.
    def update(snapshot)
      @pending = snapshot
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if !@first_update && (now - @last_flush) < @interval
      flush!(now)
    end

    # Force-write the latest pending snapshot (used in ensure blocks).
    def flush!(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
      return unless @pending
      tmp = @path + ".tmp"
      File.write(tmp, JSON.generate(@pending))
      FileUtils.chmod(0o600, tmp)
      File.rename(tmp, @path)   # POSIX atomic — same strategy as 方案一
      @last_flush = now
      @first_update = false
    rescue => e
      Clacky::Logger.warn("stream.checkpoint_flush_failed",
        error: "#{e.class}: #{e.message}", path: @path)
    end

    # Delete the checkpoint on successful completion.
    # Resets @pending so a subsequent flush! (e.g. in an ensure block)
    # does NOT re-create the file.
    def clear!
      @pending = nil
      File.delete(@path) if File.exist?(@path)
    rescue => e
      Clacky::Logger.warn("stream.checkpoint_clear_failed",
        error: "#{e.class}: #{e.message}", path: @path)
    end
  end
end
