# frozen_string_literal: true

module Clacky
  # IdleCompressionTimer triggers memory compression after a period of inactivity.
  #
  # Both CLI and WebUI use the same agent-level compression logic; this class
  # abstracts the "wait N seconds, then compress" pattern so it can be shared.
  #
  # Usage:
  #   timer = IdleCompressionTimer.new(agent: agent, session_manager: sm) do |success|
  #     # called on the compression thread after compression finishes
  #     broadcast_update if success
  #   end
  #   timer.start   # call after each agent run completes
  #   timer.cancel  # call when new user input arrives
  class IdleCompressionTimer
    # Seconds of inactivity before idle compression is triggered.
    # Kept under the 5-minute prompt cache TTL so the compression call itself
    # still hits the existing prefix cache.
    IDLE_DELAY = 314

    # @param agent [Clacky::Agent] the agent whose messages will be compressed
    # @param session_manager [Clacky::SessionManager, nil] used to persist session after compression
    # @param logger [#call, nil] optional logger lambda: ->(msg, level:) { ... }
    # @param on_compress [Proc, nil] block called after compression attempt with success (bool)
    def initialize(agent:, session_manager: nil, logger: nil, &on_compress)
      @agent           = agent
      @session_manager = session_manager
      @logger          = logger
      @on_compress     = on_compress

      @timer_thread    = nil
      @compress_thread = nil
      @mutex           = Mutex.new
      @shutdown        = false
    end

    # Start (or restart) the idle timer.
    # Cancels any existing timer first, then waits IDLE_DELAY seconds before compressing.
    def start
      cancel # reset any existing timer

      @mutex.synchronize do
        return false if @shutdown

        @timer_thread = Thread.new do
          Thread.current.name = "idle-compression-timer"
          sleep IDLE_DELAY
          next if shutdown?

          # Register @compress_thread inside the mutex BEFORE the thread starts running,
          # so cancel() can always find and interrupt it even if it fires immediately.
          compress_thread = nil
          @mutex.synchronize do
            unless @shutdown
              compress_thread = Thread.new do
                Thread.current.name = "idle-compression-work"
                run_compression
              end
              @compress_thread = compress_thread
            end
          end

          compress_thread&.join
          @mutex.synchronize { @compress_thread = nil; @timer_thread = nil }
        end
      end
      true
    rescue ThreadError => e
      log("Idle compression timer could not start: #{e.message}", level: :debug)
      false
    end

    # Cancel the timer and any in-progress compression.
    # Raises AgentInterrupted on the compress thread and waits for it to fully exit,
    # ensuring history rollback completes before the caller starts a new agent.run.
    def cancel
      compress_thread_to_join = nil

      @mutex.synchronize do
        @timer_thread&.kill
        if @compress_thread&.alive?
          @compress_thread.raise(Clacky::AgentInterrupted, "Idle timer cancelled")
          compress_thread_to_join = @compress_thread
        end
        @timer_thread    = nil
        @compress_thread = nil
      end

      # Join outside the mutex to avoid deadlock.
      # This blocks until the compress thread has finished rolling back history,
      # so the subsequent agent.run sees a clean, consistent history.
      compress_thread_to_join&.join(5)
    end

    # Permanently stop this timer. Used during application shutdown so
    # background agent-thread ensure blocks cannot create new timer threads.
    def shutdown
      @mutex.synchronize { @shutdown = true }
      cancel
    end

    # True if the timer or compression is currently active.
    def active?
      @mutex.synchronize { @timer_thread&.alive? || @compress_thread&.alive? }
    end

    # True only when compression work is actually in flight (not during the
    # pre-compression idle countdown). Used by callers that want to treat
    # Ctrl+C during active compression as "stop compressing" rather than
    # "exit the program".
    def compressing?
      @mutex.synchronize { @compress_thread&.alive? || false }
    end

    def shutdown?
      @mutex.synchronize { @shutdown }
    end

    private def run_compression
      success = @agent.trigger_idle_compression

      if success && @session_manager
        @session_manager.save(@agent.to_session_data(status: :success))
      end

      @on_compress&.call(success)
    rescue Clacky::AgentInterrupted
      log("Idle compression cancelled", level: :info)
      @on_compress&.call(false)
    rescue => e
      log("Idle compression error: #{e.message}", level: :error)
      @on_compress&.call(false)
    end

    private def log(message, level: :info)
      @logger&.call(message, level: level)
    end
  end
end
