# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "yaml"
require "fileutils"

module Clacky
  # Loads declarative, shell-based hooks from ~/.clacky/hooks.yml and registers
  # them on a HookManager. Each hook runs an external command rather than Ruby in
  # the agent process, which keeps user-authored hooks sandboxed and safe.
  #
  # hooks.yml format:
  #   hooks:
  #     before_tool_use:
  #       # Simple protocol — no `type` (or `type: command`). exit-code driven.
  #       - name: guard            # optional label for logs
  #         command: "~/.clacky/hook-scripts/guard.sh"
  #         timeout: 10            # optional, seconds (default 10)
  #
  #       # Rewrite protocol — `type: rewrite`. Rich JSON stdin/stdout, supports
  #       # matcher, updatedInput rewrite. (before_tool_use only)
  #       - type: rewrite
  #         # matcher must be the CANONICAL tool name the agent dispatches
  #         # (e.g. `terminal`), NOT an alias (`bash`/`shell`/`exec`): the
  #         # agent resolves aliases to canonical names BEFORE firing hooks,
  #         # so `matcher: bash` would never match. "*" or omitted = all tools.
  #         matcher: terminal
  #         command: "~/.clacky/hook-scripts/rewrite.sh"
  #         timeout: 30             # optional, seconds (default 60)
  #     on_complete:
  #       - command: "notify-send done"
  #
  # Runtime contract (per invocation):
  #   - The event payload is passed to the command as JSON on STDIN.
  #   - exit 0  → allow (default). Rewrite hooks parse STDOUT as hookSpecificOutput.
  #   - exit 2  → deny; STDOUT (simple) or stderr/stdout (rewrite) is the reason.
  #               Only before_tool_use is checked for {action: :deny}.
  #   - any other exit / timeout / crash → logged, treated as allow (a broken
  #     hook must never wedge the agent).
  #
  # Rewrite entries chain in config order: each applies its updatedInput IN
  # PLACE on the tool call (complete replacement — no merge); the first deny
  # stops the chain.
  class ShellHookLoader
    DEFAULT_PATH            = File.expand_path("~/.clacky/hooks.yml")
    DEFAULT_TIMEOUT         = 10
    REWRITE_DEFAULT_TIMEOUT = 60
    DENY_EXIT_CODE          = 2

    Result = Struct.new(:registered, :skipped, keyword_init: true)

    # The context procs supply rewrite-protocol context at run time; optional so
    # simple-only callers (e.g. `clacky hook_verify`) can omit them.
    def self.load_into(hook_manager, session_id_fn: nil, cwd_fn: nil, permission_mode_fn: nil, path: DEFAULT_PATH)
      new(path: path, session_id_fn: session_id_fn, cwd_fn: cwd_fn, permission_mode_fn: permission_mode_fn)
        .load_into(hook_manager)
    end

    # Create a starter hooks.yml plus an example guard script. Idempotent-ish:
    # raises if hooks.yml already exists so we never clobber user config.
    # @return [String] path to the created hooks.yml
    def self.scaffold(path: DEFAULT_PATH)
      raise ArgumentError, "hooks file already exists: #{path}" if File.exist?(path)

      dir = File.dirname(path)
      scripts_dir = File.join(dir, "hook-scripts")
      FileUtils.mkdir_p(scripts_dir)

      guard = File.join(scripts_dir, "deny-example.sh")
      File.write(guard, <<~SH)
        #!/usr/bin/env bash
        # Example before_tool_use hook.
        # Reads the event JSON on STDIN; exit 2 to DENY, exit 0 to ALLOW.
        # STDOUT on exit 2 becomes the denial reason shown to the agent.
        payload="$(cat)"
        # Example: deny any terminal command containing "rm -rf /"
        if echo "$payload" | grep -q 'rm -rf /'; then
          echo "blocked dangerous command"
          exit 2
        fi
        exit 0
      SH
      FileUtils.chmod("+x", guard)

      File.write(path, <<~YAML)
        # Declarative shell hooks. Each command receives the event payload as JSON
        # on STDIN. For before_tool_use: exit 2 = deny (STDOUT = reason), exit 0 = allow.
        # Add `type: rewrite` to a before_tool_use entry to use the rich JSON
        # protocol (updatedInput rewrite, matcher).
        # Events: #{HookManager::HOOK_EVENTS.join(", ")}
        hooks:
          before_tool_use:
            - name: deny-example
              command: "#{guard}"
              timeout: 10
        #    - type: rewrite
        #      matcher: terminal
        #      command: "~/.clacky/hook-scripts/rewrite.sh"
        #      timeout: 30
        #  on_complete:
        #    - command: "echo task finished"
      YAML

      path
    end

    def initialize(path: DEFAULT_PATH, session_id_fn: nil, cwd_fn: nil, permission_mode_fn: nil)
      @path               = path
      @session_id_fn      = session_id_fn
      @cwd_fn             = cwd_fn
      @permission_mode_fn = permission_mode_fn
    end

    # @return [Result] counts of registered hooks and skipped (with reasons)
    def load_into(hook_manager)
      result = Result.new(registered: [], skipped: [])
      return result unless File.exist?(@path)

      doc = YAMLCompat.load_file(@path) || {}
      events = doc["hooks"] || {}

      events.each do |event_name, specs|
        event = event_name.to_sym
        Array(specs).each do |spec|
          register_one(hook_manager, event, spec, result)
        end
      end

      result
    rescue StandardError => e
      Clacky::Logger.error("[ShellHookLoader] Failed to load #{@path}: #{e.message}")
      result
    end

    private def register_one(hook_manager, event, spec, result)
      if spec["type"] == "rewrite" && event != :before_tool_use
        # type: rewrite only makes sense under before_tool_use (it rewrites tool
        # input); elsewhere matcher/updatedInput would be silently ignored —
        # skip + warn so the misconfiguration is visible.
        name = (spec["name"] || spec["command"] || "rewrite hook").to_s
        result.skipped << [name, "type: rewrite is only valid under before_tool_use"]
      elsif spec["type"] == "rewrite"
        register_rewrite(hook_manager, spec, result)
      else
        register_simple(hook_manager, event, spec, result)
      end
    end

    # Returns [name, command] for a spec, or nil (after recording a skip) when
    # the command is missing. Shared by the simple and rewrite registrars.
    private def resolve_command(spec, result)
      command = spec["command"].to_s.strip
      name    = spec["name"] || command
      if command.empty?
        result.skipped << [name, "missing command"]
        nil
      else
        [name, command]
      end
    end

    private def register_simple(hook_manager, event, spec, result)
      resolved = resolve_command(spec, result)
      return unless resolved
      name, command = resolved
      timeout = (spec["timeout"] || DEFAULT_TIMEOUT).to_i

      unless HookManager::HOOK_EVENTS.include?(event)
        result.skipped << [name, "unknown event: #{event}"]
        return
      end

      hook_manager.add(event) do |*args|
        run_command(event, command, timeout, args)
      end
      result.registered << [event, name]
    end

    # Rewrite protocol (before_tool_use only): rich JSON stdin/stdout.
    private def register_rewrite(hook_manager, spec, result)
      resolved = resolve_command(spec, result)
      return unless resolved
      name, command = resolved
      timeout = (spec["timeout"] || REWRITE_DEFAULT_TIMEOUT).to_i
      matcher = spec["matcher"]

      hook_manager.add(:before_tool_use) do |call|
        tool_name = (call[:name] || call["name"]).to_s
        next { action: :allow } unless matcher_applies?(matcher, tool_name)
        run_rewrite(command, timeout, call, tool_name)
      end
      result.registered << [:before_tool_use, name]
    end

    # "*" or omitted matches every tool; otherwise the matcher must equal the
    # canonical tool name exactly (no aliases, regex, or lists).
    private def matcher_applies?(matcher, tool_name)
      matcher.nil? || matcher == "*" || matcher == tool_name
    end

    # Cap on bytes buffered per stream: before_tool_use fires on every tool
    # call, so a runaway/malicious hook could otherwise OOM the agent.
    MAX_OUTPUT_BYTES = 8 * 1024 * 1024

    # Spawn `command` in its own process group, feed `payload` on STDIN, and
    # return [stdout, stderr, status]. stdout and stderr are drained on parallel
    # reader threads — a single sequential reader deadlocks once a child fills
    # the 64KB stderr pipe while keeping stdout open. The dedicated process
    # group lets us SIGKILL the whole tree on timeout (including grandchildren
    # that inherit the fds), so a hook that traps TERM can't hang the agent.
    # Output is scrubbed to valid UTF-8 so a stray non-UTF-8 byte can't turn a
    # deny into an allow via a .strip / JSON.parse raise.
    private def capture_streams(command, payload, timeout)
      stdout = +""
      stderr = +""
      # Declared here so the block assigns this var, not a block-local one
      # (else every deny silently becomes an allow).
      status = nil

      Open3.popen3(command, pgroup: true) do |stdin, out, err, wait_thr|
        pgid = wait_thr.pid

        out_reader = Thread.new { drain_stream(out, stdout) }
        err_reader = Thread.new { drain_stream(err, stderr) }

        # Write stdin on its own thread: a child that doesn't read stdin (or a
        # payload larger than the ~64KB pipe buffer) would otherwise block the
        # main thread before it reaches wait_thr.join(timeout) — the only thing
        # enforcing the timeout — and wedge capture_streams forever.
        writer = Thread.new do
          begin
            stdin.write(payload)
          rescue Errno::EPIPE
            # Child already exited / stopped reading; its stdout may still be readable.
          rescue IOError
            # Pipes closed (timeout path) — nothing more to write.
          ensure
            stdin.close rescue nil
          end
        end

        if wait_thr.join(timeout)
          status = wait_thr.value
          # Child exited; drain the readers (bounded join — a grandchild
          # holding the pipe fd can keep them from EOF; see drain_stream).
          out_reader.join(2)
          err_reader.join(2)
        else
          # SIGTERM, then SIGKILL the whole group if it won't die. popen3's
          # ensure joins wait_thr without a timeout, so the child MUST be dead
          # before we leave the block — a hook that traps/ignores TERM can't be
          # allowed to hang here.
          Process.kill("TERM", -pgid) rescue nil
          unless wait_thr.join(1)
            Process.kill("KILL", -pgid) rescue nil
            wait_thr.join
          end
          out_reader.join(1)
          err_reader.join(1)
          writer.kill rescue nil
          raise Timeout::Error
        end
      end

      [stdout.scrub!, stderr.scrub!, status]
    end

    # Read `io` into `buf` in readpartial chunks until EOF, instead of a single
    # IO#read. readpartial returns whatever is currently available, so a
    # grandchild that inherited the pipe fd (and thus keeps it from EOF) can no
    # longer block us forever — already-read bytes are preserved in `buf`.
    # Appending stops at MAX_OUTPUT_BYTES so a runaway hook can't OOM the agent;
    # we keep draining past the cap so the child doesn't block on a full pipe.
    private def drain_stream(io, buf)
      loop do
        chunk = io.readpartial(4096)
        buf << chunk if buf.bytesize < MAX_OUTPUT_BYTES
      end
    rescue EOFError, IOError
      # EOFError: pipe closed (normal end). IOError: pipes closed on block exit.
    end

    # Strip + default, so a deny never has a blank reason.
    private def deny_reason(raw)
      s = raw.to_s.strip
      s.empty? ? "Denied by hook" : s
    end

    private def run_command(event, command, timeout, args)
      payload = JSON.generate(build_payload(event, args))

      out, _err, status = capture_streams(command, payload, timeout)

      if status&.exitstatus == DENY_EXIT_CODE
        { action: :deny, reason: deny_reason(out) }
      else
        { action: :allow }
      end
    rescue Timeout::Error
      Clacky::Logger.warn("[ShellHookLoader] Hook '#{command}' timed out after #{timeout}s — allowing")
      { action: :allow }
    rescue StandardError => e
      Clacky::Logger.warn("[ShellHookLoader] Hook '#{command}' failed: #{e.message} — allowing")
      { action: :allow }
    end

    # Normalize the positional trigger args of each event into a JSON-serializable hash.
    private def build_payload(event, args)
      base = { event: event.to_s }

      case event
      when :before_tool_use, :after_tool_use, :on_tool_error
        base[:tool] = args[0]
        base[:result] = args[1] if args.length > 1 && event == :after_tool_use
        base[:error] = args[1].to_s if event == :on_tool_error && args[1]
      when :on_start
        base[:user_input] = args[0].to_s
      when :on_iteration
        base[:iteration] = args[0]
      when :on_complete
        base[:result] = args[0]
      when :session_rollback
        base[:info] = args[0]
      end

      base
    end

    # --- Rewrite protocol (type: rewrite) -------------------------------------

    private def run_rewrite(command, timeout, call, tool_name)
      tool_input = parse_tool_args(call)
      payload    = build_rewrite_payload(tool_name, tool_input)

      stdout, stderr, status = capture_streams(command, payload, timeout)

      # nil exitstatus = killed by signal (SIGKILL/OOM) — a crash, not a clean
      # exit. Treat as allow so a partial deny payload can't deny from garbage.
      if status&.exitstatus.nil?
        Clacky::Logger.warn("[ShellHookLoader] Rewrite hook '#{command}' died (signal) — allowing")
        return { action: :allow }
      end
      exit_code = status.exitstatus

      if exit_code == DENY_EXIT_CODE
        source = stderr.strip.empty? ? stdout : stderr
        return { action: :deny, reason: deny_reason(source) }
      end

      if exit_code != 0
        Clacky::Logger.warn("[ShellHookLoader] Rewrite hook '#{command}' exited #{exit_code} (non-blocking) — allowing")
        return { action: :allow }
      end

      result = parse_hook_output(stdout)
      # Chained rewrite: apply updatedInput IN PLACE on `call` so the next
      # rewrite sees it. updatedInput is a complete replacement (no merge);
      # empty/absent means "no rewrite this time" — leave `call` untouched.
      updated = result.delete(:updated_input)
      call[:arguments] = JSON.generate(updated) if updated.is_a?(Hash) && !updated.empty?
      result
    rescue Timeout::Error
      Clacky::Logger.warn("[ShellHookLoader] Rewrite hook '#{command}' timed out after #{timeout}s — allowing")
      { action: :allow }
    rescue StandardError => e
      Clacky::Logger.warn("[ShellHookLoader] Rewrite hook '#{command}' failed: #{e.message} — allowing")
      { action: :allow }
    end

    private def build_rewrite_payload(tool_name, tool_input)
      JSON.generate({
        session_id:      @session_id_fn&.call,
        cwd:             @cwd_fn&.call || Dir.pwd,
        permission_mode: @permission_mode_fn&.call || "default",
        hook_event_name: "PreToolUse",
        tool_name:       tool_name,
        tool_input:      tool_input
      })
    end

    # Parse the tool arguments the hook should see. Unparseable JSON is logged
    # (not silently swallowed) but defers to an empty Hash so a broken payload
    # doesn't wedge the agent.
    private def parse_tool_args(call)
      args = call[:arguments] || call["arguments"]
      case args
      when String then JSON.parse(args)
      when Hash   then args
      else             {}
      end
    rescue JSON::ParserError => e
      Clacky::Logger.warn("[ShellHookLoader] Unparseable tool arguments (#{e.message}); hook sees empty input")
      {}
    end

    # Missing or unparseable hookSpecificOutput defers to allow.
    private def parse_hook_output(stdout)
      return { action: :allow } if stdout.nil? || stdout.strip.empty?

      parsed   = JSON.parse(stdout.strip)
      specific = parsed.is_a?(Hash) && parsed["hookSpecificOutput"]
      return { action: :allow } unless specific.is_a?(Hash)

      decision      = specific["permissionDecision"]
      reason        = specific["permissionDecisionReason"]
      updated_input = specific["updatedInput"]

      # Permission decision other than "deny" is treated as allow: the agent's
      # own permission_mode governs confirmation, not the hook.
      result = case decision
               when "deny"
                 { action: :deny, reason: deny_reason(reason) }
               else
                 { action: :allow }   # "allow", "ask", "defer", unknown
               end

      result[:updated_input] = updated_input if updated_input.is_a?(Hash)
      result
    rescue JSON::ParserError
      { action: :allow }
    end
  end
end