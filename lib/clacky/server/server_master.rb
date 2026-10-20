# frozen_string_literal: true

require "socket"
require "tmpdir"
require "fcntl"
require "fileutils"
require "time"
require_relative "../banner"
require_relative "../version"
require_relative "../agent_config"
require_relative "../platform_http_client"

module Clacky
  module Server
    # Master process — owns the listen socket, spawns/monitors worker processes.
    #
    # Lifecycle:
    #   clacky server
    #     └─ Master.run  (this file)
    #           ├─ creates TCPServer, holds it forever
    #           ├─ spawns Worker via spawn() — full new Ruby process, loads fresh gem
    #           ├─ traps USR1 → hot_restart (spawn new worker, gracefully stop old)
    #           └─ traps TERM/INT → shutdown (stop worker, exit cleanly)
    #
    # Worker receives:
    #   CLACKY_WORKER=1          — "I am a worker, start HttpServer directly"
    #   CLACKY_INHERIT_FD=<n>   — file descriptor number of the inherited TCPServer socket
    #   CLACKY_MASTER_PID=<n>   — master PID so worker can send USR1 back on upgrade
    class Master
      # Worker exits with this code to request a hot restart (e.g. after gem upgrade).
      RESTART_EXIT_CODE        = 75
      MAX_CONSECUTIVE_FAILURES = 5
      # Grace period for a worker to finish its shutdown_proc before KILL.
      # Worker cleanup is tuned to finish in ~2s (parallel agent interrupt,
      # 1s stopper joins, 1s force_stop grace), so 3s is the target ceiling.
      #
      # TEMP for manual debugging: extended to 10s so a slow worker teardown
      # does not get KILLed mid-cleanup while we measure where time goes.
      # Override with CLACKY_MASTER_GRACE_SECONDS (e.g. 15) without editing code.
      # Revert to 3 once the worker side is proven to finish in time.
      WORKER_GRACE_EXIT_SECONDS = ENV.fetch("CLACKY_MASTER_GRACE_SECONDS", "10").to_i

      def initialize(host:, port:, argv: nil, extra_flags: [], strict_port: false)
        @host   = host
        @port   = port
        @strict_port = strict_port
        @argv   = argv          # kept for backward compat but no longer used
        @extra_flags = extra_flags  # e.g. ["--brand-test"]

        @socket     = nil
        @worker_pid = nil
        @restart_requested = false
        @shutdown_requested = false
        @shutdown_signal = nil
        @lock_file = nil
      end

      def run
        # 0. Kill any existing master on this port before binding.
        kill_existing_master

        # Acquire the per-data-directory instance lock *before* binding. The
        # lock (an flock held for the lifetime of this process) survives PID
        # file loss — /tmp cleanup, kill -9, older gems that never wrote a PID
        # file — and is released automatically by the kernel when the process
        # dies. Without it a second launch silently binds a fallback port and
        # every IM channel connects twice, so each message is handled N times.
        acquire_instance_lock!

        # 1. Try to bind the socket.
        # If port is 7070 (default), try fallback ports 7071-7075 if occupied.
        # If port is non-default (user-specified), only try that exact port.
        original_port = @port
        max_port = (@port == 7070 && !@strict_port) ? (@port + 5) : @port
        @socket = bind_with_fallback(@host, @port, max_port: max_port)

        if @socket.nil?
          if max_port != @port
            Clacky::Logger.error("[Master] No available ports in range 7070-7075")
          else
            Clacky::Logger.error("[Master] Port #{@port} is in use")
          end
          exit(1)
        end

        @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
        @port = @socket.local_address.ip_port  # Update to actual bound port

        # 2. Print banner after port is determined
        print_banner(port_changed: @port != original_port, original_port: original_port)

        write_pid_file
        write_lock_metadata

        # 3. Signal handlers
        Signal.trap("USR1") { @restart_requested  = true }
        Signal.trap("TERM") { @shutdown_signal = "TERM"; @shutdown_requested = true }
        Signal.trap("INT")  { @shutdown_signal = "INT";  @shutdown_requested = true }
        Signal.trap("HUP")  { @shutdown_signal = "HUP";  @shutdown_requested = true }

        # 4. Spawn first worker
        @worker_pid = spawn_worker
        @consecutive_failures = 0

        # 4. Monitor loop
        loop do
          if @shutdown_requested
            shutdown
            break
          end

          if @restart_requested
            @restart_requested = false
            hot_restart
            @consecutive_failures = 0
          end

          # Non-blocking wait: check if worker has exited
          pid, status = Process.waitpid2(@worker_pid, Process::WNOHANG)
          if pid
            exit_code = status.exitstatus
            if exit_code == RESTART_EXIT_CODE
              Clacky::Logger.info("[Master] Worker requested restart (exit #{RESTART_EXIT_CODE}).")
              @worker_pid = spawn_worker
              @consecutive_failures = 0
            elsif @shutdown_requested
              break
            else
              @consecutive_failures += 1
              if @consecutive_failures >= MAX_CONSECUTIVE_FAILURES
                Clacky::Logger.error("[Master] Worker failed #{MAX_CONSECUTIVE_FAILURES} times in a row, giving up.")
                shutdown
                break
              end
              delay = [0.5 * (2 ** (@consecutive_failures - 1)), 30].min  # exponential backoff, max 30s
              Clacky::Logger.warn("[Master] Worker exited unexpectedly (exit #{exit_code}), failure #{@consecutive_failures}/#{MAX_CONSECUTIVE_FAILURES}, restarting in #{delay}s...")
              sleep delay
              @worker_pid = spawn_worker
            end
          end

          sleep 0.1
        end
      ensure
        remove_pid_file
        release_instance_lock
      end


      # Spawn a fresh Ruby process that loads the (possibly updated) gem from disk.
      # The listen socket is inherited via its file descriptor number.
      def spawn_worker
        env = {
          "CLACKY_WORKER"      => "1",
          "CLACKY_INHERIT_FD"  => @socket.fileno.to_s,
          "CLACKY_MASTER_PID"  => Process.pid.to_s
        }
        selected_source = Clacky::AgentConfig.load.clacky_license_server.to_s.strip
        unless selected_source.empty?
          env["CLACKY_LICENSE_SERVER"] =
            selected_source == Clacky::PlatformHttpClient::PRIMARY_HOST ? nil : selected_source
        end
        # Keep the socket fd open across exec — mark it as non-CLOEXEC.
        @socket.close_on_exec = false

        # Reconstruct the worker command explicitly.
        # We cannot rely on ARGV (Thor has already consumed it), so we rebuild
        # the minimal args: `clacky server --host HOST --port PORT [extra_flags]`
        ruby   = RbConfig.ruby
        script = File.expand_path($0)
        worker_argv = ["server", "--host", @host.to_s, "--port", @port.to_s] + @extra_flags

        Clacky::Logger.info("[Master PID=#{Process.pid}] spawn: #{ruby} #{script} #{worker_argv.join(' ')}")
        Clacky::Logger.info("[Master PID=#{Process.pid}] env: #{env.inspect}")

        # pgroup: 0 puts worker in its own process group.
        # This lets Master send TERM/KILL to the entire group (-pid) on shutdown,
        # ensuring grandchildren (e.g. chrome-devtools-mcp node process) are also
        # cleaned up even if the worker is force-killed before its shutdown_proc runs.
        #
        # NOTE on stdio: we deliberately let the worker inherit Master's fd 0/1/2
        # so users see startup banner / request logs in their terminal. Protection
        # against Errno::EPIPE on broken parent stdout is installed inside the
        # worker itself (see cli.rb worker entry — EPIPESafeIO wrapper).
        #
        # When running under a LaunchAgent there is no terminal, so redirect the
        # worker's stderr to the daily log file to capture crash output (e.g.
        # Ruby load errors that happen before the logger is reachable).
        if $stderr.isatty
          stderr_target = :err
        else
          Clacky::Logger.ensure_log_dir
          stderr_target = File.open(Clacky::Logger.current_log_file, "a")
        end
        pid = spawn(env, ruby, script, *worker_argv, pgroup: 0, err: stderr_target)
        stderr_target.close unless stderr_target == :err
        Clacky::Logger.info("[Master PID=#{Process.pid}] Spawned worker PID=#{pid} pgroup=#{pid}")
        pid
      end

      # Gracefully stop the old worker (so it can persist in-memory sessions),
      # wait for it to exit, then spawn a new one.
      def hot_restart
        old_pid = @worker_pid
        Clacky::Logger.info("[Master] Hot restart: stopping old worker PID=#{old_pid}...")

        # TERM the old worker's process group so grandchildren (node MCP, etc.)
        # also get a chance to shut down cleanly (triggering interrupt_all_agents).
        begin
          Process.kill("TERM", -old_pid)
          deadline = Time.now + WORKER_GRACE_EXIT_SECONDS
          loop do
            pid, = Process.waitpid2(old_pid, Process::WNOHANG)
            break if pid
            break if Time.now > deadline
            sleep 0.1
          end
          Process.kill("KILL", -old_pid) rescue nil  # force-kill entire group if still alive
        rescue Errno::ESRCH
          # already gone — fine
        end

        # Old worker is gone; now spawn the replacement.
        new_pid = spawn_worker
        @worker_pid = new_pid
        Clacky::Logger.info("[Master] Hot restart complete. New worker PID=#{new_pid}")
      end

      def shutdown
        reason = @shutdown_signal ? "signal=SIG#{@shutdown_signal}" : "signal=none"
        Clacky::Logger.info("[Master] Shutting down (worker PID=#{@worker_pid}) #{reason}...")
        if @worker_pid
          begin
            # TERM the entire worker process group so grandchildren (node MCP, etc.)
            # are also signalled and can clean up before we force-kill.
            Process.kill("TERM", -@worker_pid)
            # Wait for worker graceful exit, then KILL the whole group as a
            # last resort. Deadline must cover the worker's shutdown_proc
            # worst case (~5.5s), otherwise every Ctrl+C logs a spurious
            # "did not exit in time" and kills the worker mid-cleanup.
            deadline = Time.now + WORKER_GRACE_EXIT_SECONDS
            loop do
              pid, = Process.waitpid2(@worker_pid, Process::WNOHANG)
              break if pid
              if Time.now > deadline
                Clacky::Logger.warn("[Master] Worker did not exit in time, sending KILL...")
                Process.kill("KILL", -@worker_pid) rescue nil
                break
              end
              sleep 0.1
            end
            # A worker can exit before its browser/MCP children. They may still
            # hold the inherited listener even after the leader was reaped.
            Process.kill("KILL", -@worker_pid) rescue Errno::ESRCH
          rescue Errno::ESRCH, Errno::ECHILD
            # already gone
          end
        end
        @socket.close rescue nil
        Clacky::Logger.info("[Master] Exited.")
        exit(0)
      end

      def pid_file_path
        File.join(Dir.tmpdir, "clacky-master-#{@port}.pid")
      end

      def write_pid_file
        File.write(pid_file_path, Process.pid.to_s)
      end

      def remove_pid_file
        # A replacement may already own the port after this master was stopped.
        if File.exist?(pid_file_path) && File.read(pid_file_path).strip == Process.pid.to_s
          File.delete(pid_file_path)
        end
      end

      def port_free_within?(seconds)
        deadline = Time.now + seconds
        loop do
          begin
            TCPServer.new(@host, @port).close
            return true
          rescue Errno::EADDRINUSE
            return false if Time.now > deadline
            sleep 0.1
          end
        end
      end

      # Try to bind to preferred_port, fall back to next ports if occupied.
      # Returns the bound TCPServer, or nil if all ports in range are occupied.
      def bind_with_fallback(host, preferred_port, max_port:)
        (preferred_port..max_port).each do |port|
          begin
            server = TCPServer.new(host, port)
            Clacky::Logger.info("[Master] Bound to port #{port}") if port != preferred_port
            return server
          rescue Errno::EADDRINUSE
            next
          end
        end
        nil
      end

      def print_banner(port_changed: false, original_port: nil)
        banner = Clacky::Banner.new
        puts ""
        puts banner.colored_cli_logo
        puts banner.colored_tagline
        puts ""

        if port_changed
          puts "   [!] Port #{original_port} is in use, using #{@port} instead"
          puts ""
        end

        puts "   Web UI: #{banner.highlight("http://#{@host}:#{@port}")}"
        puts "   Version: #{Clacky::VERSION}"
        puts "   Press Ctrl-C to stop."
        puts ""
      end

      # Scan all fallback port PID files to prevent duplicate masters
      # when a previous instance bound to a non-default fallback port.
      def kill_existing_master
        max_port = (@port == 7070) ? (@port + 5) : @port
        (@port..max_port).each do |port|
          kill_master_on_port(port)
          reclaim_legacy_linux_master(port)
        end
      end

      # Last-resort reclaim for an OLD server version that has neither a PID
      # file nor the instance lock but is still listening. Only Linux can
      # identify the listener with pure stdlib (read-only parsing of /proc;
      # no external command), so this is a no-op elsewhere — the instance
      # lock below then prevents any further duplicate from being created.
      private def reclaim_legacy_linux_master(port)
        return unless RUBY_PLATFORM =~ /linux/
        return unless port_busy?(port)

        pids = linux_clacky_listeners(port)
        return if pids.empty?  # held by another program (nginx, etc.) — leave it

        pids.each { |pid| stop_clacky_pid(pid, port: port) }
        if port_busy?(port)
          Clacky::Logger.warn(
            "[Master] Port #{port} is still held by a Clacky server that could " \
            "not be stopped; not taking over this port."
          )
        else
          Clacky::Logger.info("[Master] Port #{port} reclaimed from a previous instance.")
        end
      end

      private def port_busy?(port)
        probe = TCPServer.new(@host, port)
        probe.close
        false
      rescue Errno::EADDRINUSE
        true
      end

      # PIDs listening on +port+ whose command line shows a `clacky server`
      # invocation. Pure stdlib: match the LISTEN socket inode in
      # /proc/net/tcp(6), then walk /proc/<pid>/fd to find its owner and
      # verify /proc/<pid>/cmdline. Never shells out and never signals a
      # process that is not provably a Clacky server.
      private def linux_clacky_listeners(port)
        inodes = linux_listen_inodes(port)
        return [] if inodes.empty?

        owners = []
        Dir.glob("/proc/[0-9]*/fd/*") do |fd_path|
          begin
            target = File.readlink(fd_path)
          rescue SystemCallError
            next
          end
          next unless target.start_with?("socket:[") && inodes.include?(target[8..-2])

          pid = fd_path[%r{/(\d+)/fd/}, 1]&.to_i
          owners << pid if pid && pid != Process.pid && clacky_cmdline?(pid)
        end
        owners.uniq
      end

      private def linux_listen_inodes(port)
        hex_port = format("%04X", port)
        Dir.glob("/proc/net/tcp*").flat_map do |net_file|
          begin
            File.readlines(net_file)
          rescue SystemCallError
            []
          end.drop(1).select do |line|
            fields = line.split
            fields[1].to_s.split(":").last == hex_port && fields[3] == "0A" # 0A == LISTEN
          end.map { |line| line.split[9] }
        end.compact
      end

      private def clacky_cmdline?(pid)
        cmdline = File.read("/proc/#{pid}/cmdline").tr("\0", " ").strip
        return false if cmdline.empty?

        return true if cmdline =~ /openclacky(?:\.bat|\.cmd|\.exe)?(?:\s|$).*?\bserver\b/i

        tokens = cmdline.split
        ruby_invocation = tokens.first.to_s.include?("ruby") &&
                          tokens.any? { |token| File.basename(token) == "openclacky" }
        ruby_invocation && tokens.include?("server")
      rescue SystemCallError
        false
      end

      private def kill_master_on_port(port)
        path = File.join(Dir.tmpdir, "clacky-master-#{port}.pid")
        return unless File.exist?(path)

        pid = File.read(path).strip.to_i
        if pid <= 0
          File.delete(path) rescue nil
          return
        end

        if process_dead?(pid)
          Clacky::Logger.info("[Master] Stale PID file for dead master PID=#{pid} (port=#{port}), removing.")
          File.delete(path) if File.read(path).strip == pid.to_s
          return
        end

        # The PID file is only ever written by a Clacky master, so a live PID
        # here is safe to hand over from. (Reclaim of an unidentified port
        # owner is handled separately on Linux; see linux_clacky_listeners.)
        stop_clacky_pid(pid, port: port)
      ensure
        File.delete(path) if File.exist?(path) && File.read(path).strip == pid.to_s rescue nil
      end

      # Graceful TERM/KILL of one Clacky master process, sweeping its process
      # group afterwards so an orphaned worker cannot keep the listen fd alive.
      private def stop_clacky_pid(pid, port:)
        wait_seconds = WORKER_GRACE_EXIT_SECONDS + 2
        begin
          Process.kill("TERM", pid)
          Clacky::Logger.info("[Master] Sent TERM to existing Clacky server (PID=#{pid}, port=#{port}), waiting...")

          # Let the old master finish its own worker-group KILL before killing
          # it; a shorter deadline strands the worker and its inherited socket.
          deadline = Time.now + wait_seconds
          until process_dead?(pid) || Time.now > deadline
            sleep 0.1
          end

          unless process_dead?(pid)
            Clacky::Logger.warn("[Master] PID=#{pid} still alive after #{wait_seconds}s, sending KILL...")
            Process.kill("KILL", pid) rescue Errno::ESRCH
          end

          Clacky::Logger.info("[Master] Existing Clacky server PID=#{pid} (port=#{port}) stopped.")
        rescue Errno::ESRCH
          Clacky::Logger.info("[Master] Existing Clacky server PID=#{pid} already gone.")
        rescue Errno::EPERM
          Clacky::Logger.warn("[Master] Could not stop existing Clacky server (PID=#{pid}) — permission denied.")
        ensure
          # The leader may die before reaping its own worker; the worker keeps
          # the inherited listen fd and still blocks the port. Sweep the group.
          kill_process_group!(pid)
        end
      end

      private def kill_process_group!(leader_pid)
        Process.kill("KILL", -leader_pid)
      rescue Errno::ESRCH, Errno::EPERM, Errno::ECHILD
        nil
      end

      private def process_dead?(pid)
        Process.kill(0, pid)
        false
      rescue Errno::ESRCH
        true
      rescue Errno::EPERM
        false
      end

      # ------------------------------------------------------------------
      # Per-data-directory instance lock
      # ------------------------------------------------------------------

      # One exclusive flock per CONFIG_DIR. Two servers against the same data
      # directory duplicate every IM channel connection, so the data directory
      # (not the port) is the correct single-instance key. flock needs no
      # external commands, works on Linux/macOS/Windows (Ruby 2.6+), and the
      # kernel releases it automatically however the process dies — which is
      # exactly the "PID file vanished" case we cannot otherwise recover from.
      def instance_lock_path
        File.join(Clacky::AgentConfig::CONFIG_DIR, "server.lock")
      end

      private def acquire_instance_lock!
        FileUtils.mkdir_p(Clacky::AgentConfig::CONFIG_DIR)
        @lock_file = File.open(instance_lock_path, File::RDWR | File::CREAT, 0o600)

        # Read the recorded owner BEFORE attempting the lock. A failed
        # non-blocking flock leaves the file offset at EOF, so reading the PID
        # afterwards would always return nil and make every live holder look
        # like a stale lock.
        holder = lock_holder_pid
        return if try_lock_nonblocking

        # Another live (or supposedly-live) instance holds the lock. Hand the
        # server over from it: ask it to shut down, sweep its group, then retry.
        if holder && !process_dead?(holder)
          Clacky::Logger.info("[Master] Data directory is locked by running server PID=#{holder}; taking over...")
          stop_clacky_pid(holder, port: @port)
        else
          Clacky::Logger.info("[Master] Recovering stale instance lock (holder no longer alive).")
        end

        # The old master's own shutdown path releases the flock; a KILLed one
        # releases it via the kernel. Wait briefly for that to happen.
        deadline = Time.now + (WORKER_GRACE_EXIT_SECONDS + 2)
        acquired = try_lock_nonblocking
        until acquired || Time.now > deadline
          sleep 0.1
          acquired = try_lock_nonblocking
        end
        return if acquired

        Clacky::Logger.error(
          "[Master] Refusing to start: another Clacky server is still running " \
          "against #{Clacky::AgentConfig::CONFIG_DIR} (lock holder PID=#{holder || 'unknown'}) " \
          "and could not be stopped. Stop it manually instead of running " \
          "duplicate instances (which handle every IM message multiple times)."
        )
        exit(1)
      end

      private def try_lock_nonblocking
        return false unless @lock_file
        # Lock from the start of the file. POSIX fcntl locks are record locks
        # keyed by a byte range (and the file offset at call time): without
        # rewind, two fds whose offsets are past the existing content would
        # each "succeed" locking a different empty tail range and both believe
        # they are the exclusive owner.
        @lock_file.rewind
        # flock(LOCK_NB) signals contention two different ways depending on the
        # platform/Ruby: it either returns false (macOS) or raises EWOULDBLOCK/
        # EAGAIN/EACCES (Linux). Treat both as "lock is held by someone else".
        @lock_file.flock(File::LOCK_EX | File::LOCK_NB) == 0
      rescue Errno::EWOULDBLOCK, Errno::EAGAIN, Errno::EACCES
        false
      end

      # Best-effort PID of the lock owner, read from the file's metadata. This
      # is only ever used to signal a process that *holds our own lock*, so a
      # recycled PID is harmless: a non-Clacky process cannot hold the flock.
      private def lock_holder_pid
        @lock_file.rewind
        pid = @lock_file.read.to_i
        pid.positive? ? pid : nil
      rescue StandardError
        nil
      end

      private def write_lock_metadata
        return unless @lock_file
        @lock_file.rewind
        @lock_file.truncate(0)
        @lock_file.write("#{Process.pid}\nport=#{@port}\nstarted=#{Time.now.utc.iso8601}\n")
        @lock_file.flush
      rescue StandardError
        nil
      end

      private def release_instance_lock
        return unless @lock_file
        @lock_file.flock(File::LOCK_UN) rescue nil
        @lock_file.close rescue nil
      end
    end
  end
end
