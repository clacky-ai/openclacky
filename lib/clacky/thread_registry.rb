# frozen_string_literal: true

module Clacky
  # Process-wide registry of managed threads.
  #
  # Every long-lived worker thread should be created through ThreadRegistry.spawn
  # so shutdown can wait for it, force-stop it, and report any thread that
  # refuses to die — including the backtrace of its creation site for tracing
  # stray Thread.new calls.
  #
  # Threads created with daemon: true are exempt from force_stop!; they are
  # terminated automatically when the process exits.
  module ThreadRegistry
    MUTEX = Mutex.new

    # Thread => { name:, daemon:, killable:, created_at:, backtrace: }
    ENTRIES = {}

    class << self
      # Create a managed thread.
      # @param name [String] human-readable label for logs
      # @param daemon [Boolean] true → exempt from force_stop! (dies with process)
      # @param killable [Boolean] false → never Thread#kill'd by force_stop!
      # @param block [Proc] thread body
      # @return [Thread]
      def spawn(name:, daemon: false, killable: true, &block)
        raise ArgumentError, "block required" unless block

        creation_backtrace = caller(1, 5)
        thread = Thread.new do
          begin
            Thread.current.name = name if Thread.current.respond_to?(:name=)
            block.call
          rescue Clacky::AgentInterrupted
            # Cooperative shutdown signal (Ctrl+C / server drain). A managed
            # thread reaching its top with this exception is exiting by design,
            # not failing — swallow it so the thread terminates cleanly and
            # Ruby doesn't print a "terminated with exception" backtrace.
          ensure
            unregister(Thread.current)
          end
        end

        register(thread, name: name, daemon: daemon, killable: killable, backtrace: creation_backtrace)
        thread
      end

      # Register an already-created thread (for code that cannot switch to spawn).
      def register(thread, name:, daemon: false, killable: true, backtrace: nil)
        MUTEX.synchronize do
          ENTRIES[thread] = {
            name: name, daemon: daemon, killable: killable,
            created_at: Time.now, backtrace: backtrace
          }
        end
        thread
      end

      def unregister(thread)
        MUTEX.synchronize { ENTRIES.delete(thread) }
      end

      # Wait up to grace seconds for all killable threads to exit cooperatively,
      # then Thread#kill the stragglers. Returns the threads that were killed.
      def force_stop!(grace: 5.0)
        snapshot = MUTEX.synchronize do
          ENTRIES.keys.each { |t| ENTRIES.delete(t) unless t.alive? }
          ENTRIES.map { |t, meta| [t, meta.dup] }
        end

        killable = snapshot.select { |_t, meta| meta[:killable] }
        deadline = Time.now + grace
        while Time.now < deadline && killable.any? { |t, _meta| t.alive? }
          sleep 0.05
        end

        stragglers = killable.select { |t, _meta| t.alive? }.map(&:first)
        stragglers.each(&:kill)
        # Thread#kill is asynchronous — give stragglers a moment to run their
        # ensure (unregister) so report_leaks! doesn't flag threads that did exit.
        stragglers.each { |t| t.join(0.5) rescue nil }
        stragglers
      end

      # Log WARN for every managed thread still alive (with its creation site).
      def report_leaks!
        snapshot = MUTEX.synchronize do
          ENTRIES.keys.each { |t| ENTRIES.delete(t) unless t.alive? }
          ENTRIES.map { |t, meta| [t, meta.dup] }
        end

        snapshot.each do |_thread, meta|
          Clacky::Logger.warn(
            "thread leaked after shutdown",
            thread: meta[:name] || "unnamed",
            created_from: meta[:backtrace] ? meta[:backtrace].join(" | ") : "unknown"
          )
        end
      end
    end
  end
end
