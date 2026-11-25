# frozen_string_literal: true

require "base64"
require "securerandom"

module Clacky
  module Extensions
    module Terminal
      # In-process pool of interactive shells backing the terminal panel.
      #
      # This file is loaded once via `require_relative` from handler.rb on
      # purpose: ApiExtensionLoader re-`load`s handler.rb whenever its mtime
      # changes (`ensure_fresh`), which installs a brand-new class object. Live
      # PTYs must survive that edit, so they are owned here, not by the handler.
      #
      # Wire format (all JSON, one frame per event):
      #   server → client  ext.terminal.ready   { term_id, cwd, shell, status,
      #                                           exit_code, seq, replay }
      #                    ext.terminal.output  { term_id, seq, data }
      #                    ext.terminal.exit    { term_id, exit_code }
      #   client → server  ext.terminal.attach | input | resize | close
      #
      # Data travelling in both directions is base64: PTY output is raw bytes
      # and routinely splits a multi-byte UTF-8 sequence across reads, which
      # JSON would either mangle or reject.
      class Runtime
        MAX_SESSIONS    = 6
        RING_BYTES      = 256 * 1024
        BATCH_WINDOW    = 0.016   # seconds of output coalesced into one frame
        UNATTACHED_TTL  = 60 * 60 # an unattached live shell is reaped after this
        EXITED_RETENTION = 5 * 60 # an exited shell stays listed while its pane shows the result
        MAX_INPUT_BYTES = 64 * 1024
        READ_CHUNK      = 65_536
        KILL_AFTER      = 0.8   # grace between SIGTERM and SIGKILL
        EXIT_WAIT       = 10    # hard stop for the post-mortem wait

        class CapacityError < StandardError; end
        class PlatformError < StandardError; end

        class Session
          attr_reader :id, :cwd, :shell, :pid

          def self.default_shell
            @default_shell ||= begin
              candidates = [ENV["SHELL"], "/bin/zsh", "/bin/bash", "/bin/sh"]
              candidates.map(&:to_s).find { |path| !path.empty? && File.executable?(path) } || "/bin/sh"
            end
          end

          def initialize(cwd:, cols:, rows:)
            @id          = SecureRandom.hex(6)
            @cwd         = cwd
            @shell       = self.class.default_shell
            @mutex       = Mutex.new
            @write_mutex = Mutex.new
            @subscribers = {}
            @ring        = +"".b
            @seq         = 0
            @status      = "running"
            @exit_code   = nil
            @reaper_started = false
            @closing_since = nil
            @last_seen   = Runtime.now
            spawn_pty(cols, rows)
            start_reader
          end

          def running?
            @mutex.synchronize { @status == "running" }
          end

          def attached?
            @mutex.synchronize { !@subscribers.empty? }
          end

          def last_seen_at
            @mutex.synchronize { @last_seen }
          end

          # Bind a client connection and hand it everything the shell has
          # produced so far, so a page reload restores the visible screen.
          # Snapshot and subscription happen under the same mutex as output
          # delivery, otherwise a chunk could land twice or not at all.
          def attach(conn)
            @mutex.synchronize do
              @subscribers[conn.object_id] = conn
              @last_seen = Runtime.now
              conn.send_json(
                type: "ext.terminal.ready",
                term_id: @id,
                cwd: @cwd,
                shell: @shell,
                status: @status,
                exit_code: @exit_code,
                seq: @seq,
                replay: Base64.strict_encode64(@ring)
              )
            end
            self
          end

          def detach(conn)
            @mutex.synchronize do
              @subscribers.delete(conn.object_id)
              @last_seen = Runtime.now
            end
          end

          def write(data)
            return false if data.nil? || data.empty?
            return false if data.bytesize > MAX_INPUT_BYTES

            @write_mutex.synchronize do
              return false if @writer.nil? || @writer.closed?
              @writer.write(data)
              true
            end
          rescue Errno::EIO, Errno::EPIPE, IOError
            false
          end

          def resize(cols, rows)
            cols = cols.to_i
            rows = rows.to_i
            return false unless cols.positive? && rows.positive?

            @write_mutex.synchronize do
              return false if @writer.nil? || @writer.closed?
              @writer.winsize = [rows, cols]
              true
            end
          rescue Errno::EIO, Errno::ENOTTY, Errno::EPIPE, IOError, NoMethodError
            false
          end

          def close!
            pid = @pid
            reaper = @mutex.synchronize do
              return self unless @status == "running"
              next false if @reaper_started

              @status = "closing"
              @closing_since = Runtime.now
              @reaper_started = true
            end

            signal(pid, "TERM")
            start_reaper(pid) if reaper
            self
          end

          # Synchronous kill for process shutdown. During normal operation the
          # reaper started by #close! escalates instead.
          def kill!
            signal(@pid, "KILL")
            self
          end

          # SIGTERM is advisory: an interactive shell may ignore it, and the
          # reader thread is parked in readpartial meanwhile — it only reaches
          # #wait_exit_code once the shell is gone. So the escalation to SIGKILL
          # has to run on its own thread, or a TERM-proof shell leaks the pty
          # and never reports its exit.
          private def start_reaper(pid)
            Clacky::ThreadRegistry.spawn(name: "terminal-reaper-#{@id}", daemon: true) do
              deadline = Runtime.now + EXIT_WAIT
              while Runtime.now < deadline
                sleep 0.05
                break if @mutex.synchronize { @status == "exited" }
                if Runtime.now - @closing_since.to_f >= KILL_AFTER
                  signal(pid, "KILL")
                  break
                end
              end
            end
          end

          private def signal(pid, name)
            return nil if pid.nil?

            Process.kill(name, pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end

          private def spawn_pty(cols, rows)
            begin
              require "pty"
              require "io/console"
            rescue LoadError => e
              raise PlatformError, "interactive terminals are not supported on this platform (#{e.message})"
            end

            env = { "TERM" => "xterm-256color", "COLORTERM" => "truecolor", "PWD" => @cwd }
            @reader, @writer, @pid = PTY.spawn(env, @shell, "-l", chdir: @cwd)
            begin
              @writer.winsize = [rows, cols]
            rescue Errno::ENOTTY, Errno::EIO, NoMethodError
              nil
            end
          rescue SystemCallError => e
            raise PlatformError, "could not start #{@shell}: #{e.message}"
          end

          private def start_reader
            @reader_thread = Clacky::ThreadRegistry.spawn(name: "terminal-pty-#{@id}", daemon: true) do
              read_loop
            end
          end

          # A shell answers a keystroke with a handful of tiny writes; sending
          # each as its own WebSocket frame would triple the frame count for no
          # visible gain. Coalesce whatever is already buffered into one frame.
          private def read_loop
            loop do
              batch = +"".b
              batch << @reader.readpartial(READ_CHUNK)
              deadline = Runtime.now + BATCH_WINDOW
              loop do
                break if Runtime.now >= deadline
                more = @reader.read_nonblock(READ_CHUNK, exception: false)
                break if more == :wait_readable || more.nil?
                batch << more
              end
              deliver(batch)
            end
          rescue Errno::EIO, EOFError, IOError
            nil
          ensure
            finish!
          end

          private def deliver(bytes)
            @mutex.synchronize do
              @seq += 1
              @ring << bytes
              @ring = @ring.byteslice(-RING_BYTES, RING_BYTES) if @ring.bytesize > RING_BYTES
              next if @subscribers.empty?

              encoded = Base64.strict_encode64(bytes)
              @subscribers.each_value do |conn|
                conn.send_json(type: "ext.terminal.output", term_id: @id, seq: @seq, data: encoded)
              end
            end
          end

          private def finish!
            code = wait_exit_code
            subscribers = @mutex.synchronize do
              next nil if @status == "exited"
              @status    = "exited"
              @exit_code = code
              @last_seen = Runtime.now
              @subscribers.dup
            end
            subscribers&.each_value do |conn|
              conn.send_json(type: "ext.terminal.exit", term_id: @id, exit_code: code)
            end
            close_ios
          end

          # Runs on the reader thread, so it must never block: Ruby cannot
          # interrupt a thread parked in waitpid and will wait for it forever
          # when the process exits, which hangs the whole app. Poll instead.
          # SIGKILL escalation lives in #start_reaper, not here — this method is
          # only reached once the shell is already gone.
          private def wait_exit_code
            deadline = Runtime.now + EXIT_WAIT
            loop do
              pid, status = Process.waitpid2(@pid, Process::WNOHANG)
              return status.exitstatus || (status.termsig && 128 + status.termsig) if pid
              return nil if Runtime.now > deadline

              sleep 0.02
            end
          rescue Errno::ECHILD
            nil
          end

          private def close_ios
            [@reader, @writer].each do |io|
              io.close
            rescue StandardError
              nil
            end
          end
        end

        @sessions = {}
        @mutex    = Mutex.new

        class << self
          def now
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def open(cwd:, cols: 32, rows: 120)
            sweep!
            @mutex.synchronize do
              live = @sessions.each_value.select(&:running?)
              evict_one!(live) if live.size >= MAX_SESSIONS
              live = @sessions.each_value.select(&:running?)
              raise CapacityError, "at most #{MAX_SESSIONS} terminal sessions can run at once" if live.size >= MAX_SESSIONS

              session = Session.new(cwd: cwd, cols: cols, rows: rows)
              @sessions[session.id] = session
              session
            end
          end

          def find(term_id)
            @mutex.synchronize { @sessions[term_id.to_s] }
          end

          def close(term_id)
            session = @mutex.synchronize { @sessions.delete(term_id.to_s) }
            session&.close!
            session
          end

          def detach(conn)
            sessions_snapshot.each { |session| session.detach(conn) }
          end

          def list
            sessions_snapshot.map do |session|
              { term_id: session.id, cwd: session.cwd, shell: session.shell,
                status: session.running? ? "running" : "exited", pid: session.pid }
            end
          end

          # Reap shells nobody is looking at. Runs on open() and on close, so a
          # long-idle browser tab cannot pin a PTY (and its fds) forever.
          def sweep!
            now = self.now
            stale = @mutex.synchronize do
              doomed = @sessions.each_value.select { |session| stale?(session, now) }
              doomed.each { |session| @sessions.delete(session.id) }
              doomed
            end
            stale.each { |session| session.close! if session.running? }
          end

          def close_all!
            doomed = @mutex.synchronize do
              list = @sessions.values
              @sessions = {}
              list
            end
            doomed.each(&:close!)
            doomed
          end

          # Process exit path: no grace period, nothing may outlive the app.
          def shutdown!
            close_all!.each(&:kill!)
          end

          def reset!
            shutdown!
          end

          private def sessions_snapshot
            @mutex.synchronize { @sessions.values }
          end

          # Called with the registry mutex held. Closing the tab of an
          # unattached shell must not permanently consume one of the slots, so
          # the least recently used one makes room instead of failing the new
          # request outright.
          private def evict_one!(live)
            victim = live.reject(&:attached?).min_by(&:last_seen_at)
            return unless victim

            @sessions.delete(victim.id)
            victim.close!
          end

          private def stale?(session, now)
            idle = now - session.last_seen_at
            return idle > UNATTACHED_TTL if session.running? && !session.attached?
            return false if session.running?
            idle > EXITED_RETENTION
          end
        end
      end
    end
  end
end

at_exit do
  begin
    Clacky::Extensions::Terminal::Runtime.shutdown!
  rescue StandardError
    nil
  end
end
