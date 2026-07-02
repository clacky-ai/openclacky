# frozen_string_literal: true

require "spec_helper"
require "securerandom"

RSpec.describe Clacky::ShellHookLoader do
  let(:tmp) { Dir.mktmpdir }
  let(:yml) { File.join(tmp, "hooks.yml") }

  after { FileUtils.remove_entry(tmp) }

  def write_yml(content)
    File.write(yml, content)
  end

  # Generate an executable bash script under tmp.
  def make_script(body, executable: true)
    path = File.join(tmp, "hook_#{SecureRandom.hex(4)}.sh")
    File.write(path, "#!/usr/bin/env bash\n#{body}\n")
    FileUtils.chmod("+x", path) if executable
    path
  end

  # Build a HookManager with the loader applied. Extra kwargs (session_id_fn,
  # cwd_fn, permission_mode_fn) forward to load_into for rewrite-protocol context.
  def build_hm(**opts)
    hm = Clacky::HookManager.new
    described_class.load_into(hm, path: yml, **opts)
    hm
  end

  def trigger(hm, tool_name, arguments = {})
    hm.trigger(:before_tool_use, { name: tool_name, arguments: JSON.generate(arguments) })
  end

  describe ".load_into" do
    it "returns empty when the file is absent" do
      result = described_class.load_into(Clacky::HookManager.new, path: File.join(tmp, "none.yml"))
      expect(result.registered).to be_empty
      expect(result.skipped).to be_empty
    end

    it "is a no-op when the file is invalid YAML" do
      File.write(yml, "{ bad: yaml: content: [")
      expect { described_class.load_into(Clacky::HookManager.new, path: yml) }.not_to raise_error
    end

    it "registers a hook for a valid event" do
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - name: guard
              command: "true"
      YAML
      hm = Clacky::HookManager.new
      result = described_class.load_into(hm, path: yml)

      expect(result.registered).to eq([[:before_tool_use, "guard"]])
      expect(hm.has_hooks?(:before_tool_use)).to be true
    end

    it "skips an unknown event" do
      write_yml(<<~YAML)
        hooks:
          not_a_real_event:
            - command: "true"
      YAML
      result = described_class.load_into(Clacky::HookManager.new, path: yml)
      expect(result.skipped.first[1]).to include("unknown event")
    end

    it "skips a spec with no command" do
      write_yml(<<~YAML)
        hooks:
          on_start:
            - name: nope
      YAML
      result = described_class.load_into(Clacky::HookManager.new, path: yml)
      expect(result.skipped.first[1]).to include("missing command")
    end

    it "skips a rewrite entry with no command" do
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              name: empty
      YAML
      result = described_class.load_into(Clacky::HookManager.new, path: yml)
      expect(result.skipped.first[1]).to include("missing command")
      expect(result.registered).to be_empty
    end

    it "skips a type: rewrite entry under a non-before_tool_use event" do
      script = make_script("exit 0")
      write_yml(<<~YAML)
        hooks:
          on_complete:
            - type: rewrite
              name: misplaced
              command: "#{script}"
      YAML
      result = described_class.load_into(Clacky::HookManager.new, path: yml)
      expect(result.registered).to be_empty
      expect(result.skipped.first[1]).to include("before_tool_use")
    end
  end

  describe "type dispatch" do
    it "treats an entry with no type as the simple protocol (exit 2 → deny, STDOUT reason)" do
      script = make_script("echo 'nope'; exit 2")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("nope")
    end

    it "treats type: command as the simple protocol" do
      script = make_script("echo 'nope'; exit 2")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: command
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("nope")
    end

    it "routes type: rewrite to the rich JSON protocol" do
      script = make_script(<<~BASH)
        printf '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"policy"}}'
      BASH
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("policy")
    end
  end

  describe "runtime contract (simple protocol)" do
    it "denies a tool when the command exits 2, using STDOUT as the reason" do
      script = File.join(tmp, "deny.sh")
      File.write(script, "#!/usr/bin/env bash\necho \"nope\"\nexit 2\n")
      FileUtils.chmod("+x", script)
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "#{script}"
      YAML
      hm = Clacky::HookManager.new
      described_class.load_into(hm, path: yml)

      result = hm.trigger(:before_tool_use, { name: "terminal" })
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("nope")
    end

    it "allows when the command exits 0" do
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "true"
      YAML
      hm = Clacky::HookManager.new
      described_class.load_into(hm, path: yml)

      result = hm.trigger(:before_tool_use, { name: "terminal" })
      expect(result[:action]).to eq(:allow)
    end

    it "passes the event payload as JSON on STDIN" do
      out = File.join(tmp, "captured.json")
      script = File.join(tmp, "capture.sh")
      File.write(script, "#!/usr/bin/env bash\ncat > \"#{out}\"\nexit 0\n")
      FileUtils.chmod("+x", script)
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "#{script}"
      YAML
      hm = Clacky::HookManager.new
      described_class.load_into(hm, path: yml)
      hm.trigger(:before_tool_use, { name: "terminal", arguments: { cmd: "ls" } })

      payload = JSON.parse(File.read(out))
      expect(payload["event"]).to eq("before_tool_use")
      expect(payload["tool"]["name"]).to eq("terminal")
    end

    it "allows (does not raise) when the command times out" do
      script = File.join(tmp, "slow.sh")
      File.write(script, "#!/usr/bin/env bash\nsleep 5\nexit 2\n")
      FileUtils.chmod("+x", script)
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "#{script}"
              timeout: 1
      YAML
      hm = Clacky::HookManager.new
      described_class.load_into(hm, path: yml)

      result = hm.trigger(:before_tool_use, { name: "terminal" })
      expect(result[:action]).to eq(:allow)
    end
  end

  # ── Rewrite protocol (type: rewrite) ────────────────────────────────────────

  describe "rewrite protocol — matcher" do
    it "skips execution when matcher does not match the tool name" do
      deny_script = make_script("echo 'blocked'; exit 2")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              matcher: terminal
              command: "#{deny_script}"
      YAML
      result = trigger(build_hm, "file_reader")
      expect(result[:action]).to eq(:allow)
    end

    it "runs the hook when matcher matches exactly" do
      deny_script = make_script("echo 'blocked'; exit 2")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              matcher: terminal
              command: "#{deny_script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:deny)
    end

    it "runs for all tools when matcher is '*'" do
      deny_script = make_script("echo 'blocked'; exit 2")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              matcher: "*"
              command: "#{deny_script}"
      YAML
      result = trigger(build_hm, "anything")
      expect(result[:action]).to eq(:deny)
    end

    it "runs for all tools when matcher is absent" do
      deny_script = make_script("exit 2")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{deny_script}"
      YAML
      result = trigger(build_hm, "write")
      expect(result[:action]).to eq(:deny)
    end
  end

  describe "rewrite protocol — exit code semantics" do
    it "denies when the script exits 2, using stderr as reason" do
      script = make_script("echo 'bad' >&2; exit 2")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("bad")
    end

    it "falls back to stdout as denial reason when stderr is empty on exit 2" do
      script = make_script("echo 'reason from stdout'; exit 2")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("reason from stdout")
    end

    it "allows (non-blocking) when the script exits with a non-zero code other than 2" do
      script = make_script("exit 1")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:allow)
    end

    it "allows when the script exits 0 with no stdout" do
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "true"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:allow)
    end

    it "allows when the script times out" do
      script = make_script("sleep 10; exit 2")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
              timeout: 1
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:allow)
    end

    it "treats a hook killed by a signal (nil exitstatus) as allow, not deny" do
      # kill -9 $$ ends the shell via SIGKILL → exitstatus is nil. Even though
      # the hook wrote a deny payload first, a crash must defer to allow rather
      # than route through parse_hook_output's success path.
      script = make_script(<<~BASH)
        printf '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"should-not-apply"}}'
        kill -9 $$
      BASH
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:allow)
    end
  end

  describe "rewrite protocol — hookSpecificOutput" do
    it "denies when permissionDecision is 'deny'" do
      script = make_script(<<~BASH)
        printf '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"policy"}}'
      BASH
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("policy")
    end

    it "denies with a default reason when 'deny' has no permissionDecisionReason" do
      script = make_script(<<~BASH)
        printf '{"hookSpecificOutput":{"permissionDecision":"deny"}}'
      BASH
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("Denied by hook")
    end

    it "uses the default reason when permissionDecisionReason is an empty string" do
      script = make_script(<<~BASH)
        printf '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":""}}'
      BASH
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("Denied by hook")
    end

    it "treats any non-deny decision as a bare allow" do
      script = make_script(<<~BASH)
        printf '{"hookSpecificOutput":{"permissionDecision":"allow"}}'
      BASH
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result).to eq(action: :allow)
    end

    it "allows when valid JSON has no hookSpecificOutput" do
      script = make_script("printf '{\"status\":\"ok\"}'")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result).to eq(action: :allow)
    end

    it "defers when stdout is empty on exit 0" do
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "true"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:allow)
    end

    it "defers when stdout is non-JSON on exit 0" do
      script = make_script("echo 'some log'")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:allow)
    end

    it "applies updatedInput from hookSpecificOutput in place on the tool call" do
      script = make_script(<<~BASH)
        printf '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"rtk git status"}}}'
      BASH
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML
      hm = build_hm
      call = { name: "terminal", arguments: JSON.generate({ "command" => "git status" }) }
      result = hm.trigger(:before_tool_use, call)
      expect(result[:action]).to eq(:allow)
      expect(JSON.parse(call[:arguments])).to eq({ "command" => "rtk git status" })
    end
  end

  describe "rewrite protocol — stdin payload" do
    it "sends hook_event_name, tool_name, and tool_input as JSON on stdin" do
      capture_file = File.join(tmp, "captured.json")
      script = make_script("cat > '#{capture_file}'")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              matcher: terminal
              command: "#{script}"
      YAML

      trigger(build_hm, "terminal", { "command" => "ls -la" })

      payload = JSON.parse(File.read(capture_file))
      expect(payload["hook_event_name"]).to eq("PreToolUse")
      expect(payload["tool_name"]).to eq("terminal")
      expect(payload["tool_input"]["command"]).to eq("ls -la")
    end

    it "injects session_id, cwd, and permission_mode from context lambdas" do
      capture_file = File.join(tmp, "captured.json")
      script = make_script("cat > '#{capture_file}'")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
      YAML

      hm = build_hm(
        session_id_fn:      -> { "sess-42" },
        cwd_fn:             -> { "/project" },
        permission_mode_fn: -> { "auto_approve" }
      )
      hm.trigger(:before_tool_use, { name: "terminal", arguments: "{}" })

      payload = JSON.parse(File.read(capture_file))
      expect(payload["session_id"]).to eq("sess-42")
      expect(payload["cwd"]).to eq("/project")
      expect(payload["permission_mode"]).to eq("auto_approve")
    end
  end

  describe "coexistence and ordering" do
    it "registers both a simple and a rewrite entry from one file (registration only)" do
      rewrite_script = make_script("printf '{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"r\"}}}'")
      simple_script = make_script("exit 0")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              name: rewriter
              command: "#{rewrite_script}"
            - name: simple
              command: "#{simple_script}"
      YAML
      result = described_class.load_into(Clacky::HookManager.new, path: yml)
      expect(result.registered).to eq([[:before_tool_use, "rewriter"], [:before_tool_use, "simple"]])
    end

    it "applies an earlier rewrite's updatedInput even when a later simple hook allows" do
      rewrite_script = make_script(<<~BASH)
        printf '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"rewritten"}}}'
      BASH
      simple_script = make_script("exit 0")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{rewrite_script}"
            - command: "#{simple_script}"
      YAML
      hm = build_hm
      call = { name: "terminal", arguments: JSON.generate({ "command" => "orig" }) }
      result = hm.trigger(:before_tool_use, call)
      expect(result[:action]).to eq(:allow)
      expect(JSON.parse(call[:arguments])).to eq({ "command" => "rewritten" })
    end

    it "deny from a simple entry wins over a rewrite entry's updatedInput" do
      rewrite_script = make_script(<<~BASH)
        printf '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"rewritten"}}}'
      BASH
      deny_script = make_script("echo 'blocked'; exit 2")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{rewrite_script}"
            - command: "#{deny_script}"
      YAML
      result = trigger(build_hm, "terminal", { "command" => "orig" })
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("blocked")
      expect(result).not_to have_key(:updated_input)
    end

    it "keeps the first deny's reason when two hooks both deny (first-deny-wins)" do
      first = make_script("echo 'first-reason'; exit 2")
      second = make_script("echo 'second-reason'; exit 2")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - name: first
              command: "#{first}"
            - name: second
              command: "#{second}"
      YAML
      result = trigger(build_hm, "terminal")
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("first-reason")
    end

    it "chains: a later rewrite sees the previous rewrite's updated input" do
      # First rewrite: whatever it received → updatedInput {command: "first"}.
      first = make_script("printf '{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"first\"}}}'")
      # Second rewrite: echoes the command it RECEIVED on stdin into the
      # rewritten value, proving it saw "first" (not the original "orig").
      second = make_script(<<~'BASH')
        payload="$(cat)"
        cmd="$(printf '%s' "$payload" | ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("tool_input","command")')"
        printf '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"%s->second"}}}' "$cmd"
      BASH
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{first}"
            - type: rewrite
              command: "#{second}"
      YAML
      hm = build_hm
      call = { name: "terminal", arguments: JSON.generate({ "command" => "orig" }) }
      hm.trigger(:before_tool_use, call)
      expect(JSON.parse(call[:arguments])["command"]).to eq("first->second")
    end

    it "chains: updatedInput is a complete replacement, not a merge" do
      # First rewrite sets {command: "x", cwd: "/a"}; second sets {command: "y"}
      # only. The final input must be exactly {command: "y"} — cwd is gone.
      first = make_script("printf '{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"x\",\"cwd\":\"/a\"}}}'")
      second = make_script("printf '{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"y\"}}}'")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{first}"
            - type: rewrite
              command: "#{second}"
      YAML
      hm = build_hm
      call = { name: "terminal", arguments: JSON.generate({ "command" => "orig" }) }
      hm.trigger(:before_tool_use, call)
      expect(JSON.parse(call[:arguments])).to eq({ "command" => "y" })
    end
  end

  describe "robustness — process group, timeout, encoding" do
    # Each of these mirrors a real hang / leak / wrong-decision found in
    # capture_streams; they must stay green.

    # Run the trigger on a side thread and assert it finishes within `within`
    # seconds — a hang shows up as join returning nil. The thread is killed in
    # an ensure so a hung hook can't outlive the example.
    def trigger_within(within, hm, *args)
      ran = Thread.new { hm.trigger(:before_tool_use, *args) }
      yield ran.join(within), ran
    ensure
      ran.kill if ran&.alive?
    end

    it "does not hang when the hook backgrounds a process that inherits stdout" do
      script = make_script("sleep 30 & exit 0")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "#{script}"
              timeout: 5
      YAML
      trigger_within(10, build_hm, { name: "terminal" }) do |joined, _|
        expect(joined).to be_a(Thread)            # returned, didn't wait ~30s
        expect(joined.value[:action]).to eq(:allow) # exit 0 → allow
      end
    end

    it "does not hang when the hook ignores SIGTERM on timeout" do
      script = make_script("trap '' TERM; sleep 30")
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "#{script}"
              timeout: 1
      YAML
      trigger_within(8, build_hm, { name: "terminal" }) do |joined, _|
        expect(joined).to be_a(Thread)            # SIGKILL'd the group, not ~30s
        expect(joined.value[:action]).to eq(:allow) # timeout → allow
      end
    end

    it "scrubs non-UTF-8 bytes in a deny reason instead of degrading to allow" do
      script = make_script(<<~'BASH')
        printf '\x80denied'
        exit 2
      BASH
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "#{script}"
      YAML
      # The bug only manifests when stdout is read as UTF-8 (the invalid byte
      # makes .strip raise, escaping to a blanket allow); force that external
      # encoding for this example and restore it after.
      orig = Encoding.default_external
      begin
        Encoding.default_external = Encoding::UTF_8
        result = build_hm.trigger(:before_tool_use, { name: "terminal" })
        expect(result[:action]).to eq(:deny)
        expect(result[:reason]).to include("denied")
      ensure
        Encoding.default_external = orig
      end
    end

    it "does not deadlock on a hook that writes >64KB to stderr" do
      # Sequential stdout-then-stderr reading deadlocks once stderr fills the
      # 64KB pipe buffer; parallel readers drain both. Rewrite hooks take the
      # deny reason from stderr, so it must be captured, not lost to a timeout.
      script = make_script(<<~'BASH')
        yes x | head -c 100000 >&2
        echo 'reason-marker' >&2
        exit 2
      BASH
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - type: rewrite
              command: "#{script}"
              timeout: 5
      YAML
      trigger_within(8, build_hm, { name: "terminal", arguments: JSON.generate({}) }) do |joined, _|
        expect(joined).to be_a(Thread)             # didn't deadlock to timeout
        expect(joined.value[:action]).to eq(:deny)
        expect(joined.value[:reason]).to include("reason-marker")
      end
    end
  end

  describe ".scaffold" do
    it "creates hooks.yml and an executable example script" do
      path = described_class.scaffold(path: yml)
      expect(File.exist?(path)).to be true
      expect(File.read(path)).to include("before_tool_use")
      expect(File.read(path)).to include("type: rewrite")

      script = File.join(tmp, "hook-scripts", "deny-example.sh")
      expect(File.exist?(script)).to be true
      expect(File.executable?(script)).to be true
    end

    it "raises if hooks.yml already exists" do
      described_class.scaffold(path: yml)
      expect { described_class.scaffold(path: yml) }.to raise_error(ArgumentError, /already exists/)
    end
  end
end
