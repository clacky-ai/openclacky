# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "securerandom"

module Clacky
  module Tools
    class Terminal < Base
      # In-process registry of interactive PTY sessions.
      #
      # Lifecycle: sessions die with the openclacky process because the child
      # bash is a grandchild of openclacky (PTY.spawn forks then execs), and
      # we also SIGKILL them on interpreter exit via an at_exit hook.
      #
      # Thread-safety: all mutations go through a class-level Mutex.  The
      # reader thread writes to Session#log_io concurrently with the main
      # thread reading log_file, but File IO is append-safe on POSIX so we
      # don't need to lock reads — we just pin them by byte offset.
      #
      # Status values:
      #   "starting" - PTY spawned, setup in progress
      #   "running"  - ready to receive commands
      #   "exited"   - child process ended
      #   "killed"   - we signalled it
      class SessionManager
        Session = Struct.new(
          :id,              # Integer, 1-based unique id within this openclacky process
          :pid,             # Integer, PID of the PTY child
          :command,         # String, original command launched
          :cwd,             # String, working directory at launch
          :started_at,      # Time
          :log_file,        # String path, raw PTY output append-only
          :log_io,          # File, write handle owned by reader thread
          :reader,          # IO, PTY read end
          :writer,          # IO, PTY write end
          :reader_thread,   # Thread, reads PTY → log file
          :status,          # "starting" | "running" | "exited" | "killed"
          :exit_code,       # Integer or nil
          :mode,            # "shell" (marker-based) | "raw" (idle-based)
          :marker_token,    # String, unique per-session token for PROMPT_COMMAND
          :marker_regex,    # Regexp, compiled match for marker
          :read_offset,     # Integer, bytes already returned by previous read calls
          :mutex,           # per-session mutex for PTY writes
          :shell_name,      # "zsh" | "bash" | "sh" — informs marker syntax & rc reload
          keyword_init: true
        )

        @sessions = {}
        @next_id  = 0
        @mutex    = Mutex.new
        @reaper_thread = nil
        @reaper_parent_pid = nil

        class << self
          # Register a new session.  Caller has already spawned the PTY and
          # started the reader thread; we just record the metadata.
          def register(pid:, command:, cwd:, log_file:, log_io:, reader:, writer:,
                       reader_thread:, mode:, marker_token: nil, shell_name: nil)
            @mutex.synchronize do
              @next_id += 1
              session = Session.new(
                id: @next_id,
                pid: pid,
                command: command,
                cwd: cwd,
                started_at: Time.now,
                log_file: log_file,
                log_io: log_io,
                reader: reader,
                writer: writer,
                reader_thread: reader_thread,
                status: "starting",
                exit_code: nil,
                mode: mode,
                marker_token: marker_token,
                marker_regex: marker_token ? /__CLACKY_DONE_#{marker_token}_(\d+)__/ : nil,
                read_offset: 0,
                mutex: Mutex.new,
                shell_name: shell_name
              )
              @sessions[session.id] = session
              session
            end
          end

          def get(id)
            @mutex.synchronize { @sessions[id] }
          end

          def list
            refresh_all
            @mutex.synchronize { @sessions.values.sort_by(&:id) }
          end

          # Send signal to child, mark as killed.  Returns the Session, or nil
          # if unknown.
          def kill(id, signal: "TERM")
            session = @mutex.synchronize { @sessions[id] }
            return nil unless session

            begin
              Process.kill(signal, session.pid)
            rescue Errno::ESRCH, Errno::EPERM
              # Already dead — fall through and mark killed.
            end

            @mutex.synchronize do
              if session.status == "starting" || session.status == "running"
                session.status = "killed"
              end
            end
            session
          end

          # Forget a session (after it has been killed/exited).  Does NOT kill
          # the process — callers should kill first.
          def forget(id)
            @mutex.synchronize { @sessions.delete(id) }
          end

          # Refresh status of one session in-place (mutex-held).
          private def refresh_locked(session)
            return unless session.status == "starting" || session.status == "running"

            # Probe the child with kill(0).
            begin
              Process.kill(0, session.pid)
            rescue Errno::ESRCH
              session.status = "exited"
            rescue Errno::EPERM
              # Process exists but owned by someone else; keep as-is.
            end
          end

          def refresh_all
            @mutex.synchronize do
              @sessions.each_value { |s| refresh_locked(s) }
            end
          end

          def refresh(id)
            @mutex.synchronize do
              session = @sessions[id]
              refresh_locked(session) if session
              session
            end
          end

          # Mark running (called by the Terminal action after setup completes).
          def mark_running(id)
            @mutex.synchronize do
              session = @sessions[id]
              session.status = "running" if session && session.status == "starting"
            end
          end

          def advance_offset(id, new_offset)
            @mutex.synchronize do
              s = @sessions[id]
              s.read_offset = new_offset if s
            end
          end

          def log_dir
            @log_dir ||= begin
              dir = File.join(Dir.tmpdir, "clacky-terminals-#{Process.pid}")
              FileUtils.mkdir_p(dir)
              dir
            end
          end

          def allocate_log_file
            @mutex.synchronize do
              next_id = @next_id + 1
              File.join(log_dir, "#{next_id}.log")
            end
          end

          # Kill every live session and close any open fds. Called from at_exit.
          def kill_all!
            (@sessions.values rescue []).each do |s|
              begin
                Process.kill("KILL", s.pid) unless %w[exited killed].include?(s.status.to_s)
              rescue StandardError
                # ignore
              end
              s.log_io&.close rescue nil
              s.writer&.close rescue nil
              s.reader&.close rescue nil
            end
          end

          # Reap orphaned PTY sessions when the openclacky process dies
          # uncleanly (`kill -9`, Ruby crash, OOM, `wsl --shutdown`,
          # power loss, ...).
          #
          # The at_exit hook in this file only fires on a normal
          # interpreter exit, so on SIGKILL / hard crash the PTY
          # children get reparented to PID 1 and keep burning CPU
          # (and on Windows/WSL each one leaves a residual headless
          # `conhost.exe` on the Windows side). This is the same class
          # of bug Linux daemons solve with `prctl(PR_SET_PDEATHSIG)`,
          # which Ruby doesn't expose — so we run a tiny watchdog
          # thread that polls `Process.ppid` and, if the parent PID
          # changes (the parent died and we were reparented to init /
          # the Windows reaper), SIGKILLs every tracked PTY child.
          #
          # The watchdog is cheap (~1 syscall/sec), only starts once
          # per process, and is a no-op when no PTY sessions exist.
          # It also installs fast-path Signal.trap handlers for
          # SIGTERM / SIGINT / SIGHUP so a clean `kill <pid>` doesn't
          # have to wait for the at_exit round trip.
          #
          # Test-only: call with parent_pid: to inject a synthetic
          # parent and force the reaper to think it died. Pass
          # interval: to skip the sleep in tight tests.
          def start_reaper!(parent_pid: Process.ppid, interval: 1.0)
            @mutex.synchronize do
              return @reaper_thread if @reaper_thread
              @reaper_parent_pid = parent_pid
            end

            # Fast-path signal handlers: deliver the same kill_all!
            # we get from at_exit, but immediately. Restoring the
            # previous handler means a second SIGTERM (after we've
            # already cleaned up) falls through to the default
            # behavior and actually terminates us.
            %w[TERM INT HUP].each do |sig|
              Signal.trap(sig) do
                begin
                  kill_all!
                rescue StandardError
                  # never raise out of a trap
                end
                # Re-raise so the default disposition still runs.
                Signal.trap(sig, "DEFAULT")
                Process.kill(sig, Process.pid)
              end
            end

            @reaper_thread = Thread.new do
              loop do
                begin
                  if Process.ppid != @reaper_parent_pid
                    # Parent is gone — we are reparented. Best-effort
                    # SIGKILL the tracked PTY children and exit; the
                    # Ruby process would be torn down by the kernel
                    # init / Windows reaper momentarily anyway.
                    kill_all!
                    break
                  end
                rescue StandardError
                  # ppid can race; just retry.
                end
                sleep interval
              end
            end
            @reaper_thread
          end

          # Test-only: stop the reaper and clear state.
          def stop_reaper!
            @mutex.synchronize do
              @reaper_thread&.kill
              @reaper_thread = nil
              @reaper_parent_pid = nil
            end
          end

          # Test-only: clear state without killing processes.
          def reset!
            @mutex.synchronize do
              @sessions.clear
              @next_id = 0
              @log_dir = nil
            end
            stop_reaper!
          end
        end
      end
    end
  end
end

# Ensure orphaned PTY children are reaped even on unclean exit.
# The at_exit hook below fires on a normal interpreter exit; the
# reaper thread started by SessionManager.start_reaper! covers the
# unclean case (SIGKILL, Ruby crash, OOM, wsl --shutdown, ...).
at_exit do
  begin
    Clacky::Tools::Terminal::SessionManager.kill_all!
  rescue StandardError
    # never raise out of at_exit
  end
end

# Start the orphan-PTY watchdog as soon as this file is loaded.
# Idempotent: calling start_reaper! more than once is a no-op, so
# tools / servers that explicitly start it again are harmless.
begin
  Clacky::Tools::Terminal::SessionManager.start_reaper!
rescue StandardError
  # Best-effort: if we can't start the reaper (e.g. a weird test
  # harness that has stubbed Process.ppid), fall back to the at_exit
  # path. The bug is still better than it was before this commit.
end
