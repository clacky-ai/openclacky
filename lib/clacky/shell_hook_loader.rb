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
  #       - name: guard            # optional label for logs
  #         command: "~/.clacky/hook-scripts/guard.sh"
  #         timeout: 10            # optional, seconds (default 10)
  #     on_complete:
  #       - command: "notify-send done"
  #
  # Runtime contract (per invocation):
  #   - The event payload is passed to the command as JSON on STDIN.
  #   - exit 0  → allow (default).
  #   - exit 2  → deny; STDOUT becomes the denial reason. Only meaningful for
  #               before_tool_use, which the agent checks for {action: :deny}.
  #   - any other exit / timeout / crash → logged, treated as allow (a broken
  #     hook must never wedge the agent).
  class ShellHookLoader
    DEFAULT_PATH    = File.expand_path("~/.clacky/hooks.yml")
    DEFAULT_TIMEOUT = 10
    DENY_EXIT_CODE  = 2

    Result = Struct.new(:registered, :skipped, keyword_init: true)

    def self.load_into(hook_manager, path: DEFAULT_PATH)
      new(path: path).load_into(hook_manager)
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
        # Events: #{HookManager::HOOK_EVENTS.join(", ")}
        hooks:
          before_tool_use:
            - name: deny-example
              command: "#{guard}"
              timeout: 10
        #  on_complete:
        #    - command: "echo task finished"
      YAML

      path
    end

    def initialize(path: DEFAULT_PATH)
      @path = path
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
      command = spec["command"].to_s.strip
      name    = spec["name"] || command
      timeout = (spec["timeout"] || DEFAULT_TIMEOUT).to_i

      if command.empty?
        result.skipped << [name, "missing command"]
        return
      end

      unless HookManager::HOOK_EVENTS.include?(event)
        result.skipped << [name, "unknown event: #{event}"]
        return
      end

      hook_manager.add(event) do |*args|
        run_command(event, command, timeout, args)
      end
      result.registered << [event, name]
    end

    private def run_command(event, command, timeout, args)
      payload = JSON.generate(build_payload(event, args))

      out = +""
      status = nil
      Open3.popen3(command) do |stdin, stdout, _stderr, wait_thr|
        stdin.write(payload)
        stdin.close
        if wait_thr.join(timeout)
          out = stdout.read
          status = wait_thr.value
        else
          Process.kill("TERM", wait_thr.pid) rescue nil
          raise Timeout::Error
        end
      end

      if status&.exitstatus == DENY_EXIT_CODE
        { action: :deny, reason: out.strip.empty? ? "Denied by hook" : out.strip }
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
  end
end