# frozen_string_literal: true

module Clacky
  # Process-wide cooperative shutdown flag.
  #
  # Signal traps must never do heavy work — they only call request!(reason) and
  # wake the shutdown coordinator thread. Long-running loops poll requested? at
  # safe points and exit cleanly; threads blocked in IO are released by the
  # coordinator closing their sockets (see Client#close_connections!).
  module Shutdown
    MUTEX = Mutex.new

    # Seconds between requested? polls while sleeping, so a sleeping thread
    # notices shutdown within one slice instead of waiting out a long sleep.
    INTERRUPT_SLICE = 0.2

    class << self
      def request!(reason = :unknown)
        MUTEX.synchronize do
          @requested = true
          @reason    = reason
          @requested_at = Time.now
        end
      end

      def requested?
        MUTEX.synchronize { !!@requested }
      end

      def reason
        MUTEX.synchronize { @reason }
      end

      def reset!
        MUTEX.synchronize do
          @requested = nil
          @reason    = nil
          @requested_at = nil
        end
      end

      # Sleep for total seconds but wake every INTERRUPT_SLICE to poll
      # requested?. Returns true if shutdown was requested while sleeping.
      def sleep_interruptibly(seconds)
        deadline = Time.now + seconds
        loop do
          return true if requested?

          remaining = deadline - Time.now
          return false if remaining <= 0

          Kernel.sleep [remaining, INTERRUPT_SLICE].min
        end
      end

      # Cooperative checkpoint: raise AgentInterrupted if shutdown was
      # requested. Long-running loops call this at safe points so they exit
      # cleanly instead of blocking the process shutdown.
      def checkpoint!
        raise Clacky::AgentInterrupted, "shutdown requested" if requested?
      end

      # Sleep for total seconds, raising AgentInterrupted if shutdown is
      # requested while sleeping. Callers don't need to check the return
      # value — the exception unwinds the loop for them.
      def sleep(seconds)
        raise Clacky::AgentInterrupted, "shutdown requested" if sleep_interruptibly(seconds)
      end
    end
  end
end
