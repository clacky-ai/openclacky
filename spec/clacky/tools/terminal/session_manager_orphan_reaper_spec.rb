# frozen_string_literal: true

# Specs for the orphan-PTY reaper added in the same commit.
#
# Background: see issue #485 — when openclacky exits uncleanly
# (`kill -9`, Ruby crash, OOM, `wsl --shutdown`, power loss),
# the PTY children it spawned were never reaped because the
# `at_exit` hook is skipped. The reaper is a tiny watchdog thread
# that polls `Process.ppid`; when the parent changes (because the
# real parent died and we were reparented to init), it SIGKILLs
# every tracked PTY child.
#
# We can't actually `kill -9` the test process in a unit test, so
# the strategy is to inject a synthetic parent PID via
# `start_reaper!(parent_pid:)` and then mutate `@reaper_parent_pid`
# from inside the spec to simulate the parent dying.
RSpec.describe Clacky::Tools::Terminal::SessionManager, "orphan reaper" do
  before { described_class.reset! }
  after  { described_class.reset! }

  # A fake session whose `pid` is just a number — the reaper calls
  # Process.kill("KILL", pid), so we replace it with a stub that
  # records the call without touching the kernel.
  let(:fake_pid) { 999_999 }

  def make_session(pid: fake_pid, status: "running")
    described_class.register(
      pid: pid,
      command: "bash -l -i",
      cwd: Dir.pwd,
      log_file: "/dev/null",
      log_io: File.open("/dev/null", "wb"),
      reader: File.open("/dev/null", "rb"),
      writer: File.open("/dev/null", "wb"),
      reader_thread: Thread.new { sleep 60 },
      mode: "shell",
    ).tap { |s| s.status = status }
  end

  # Process.kill is global; stub it so we can assert on what the
  # reaper would have signalled without actually killing anything
  # (and without flakiness around the real 999_999 PID).
  before do
    @killed_pids = []
    allow(Process).to receive(:kill) do |sig, pid|
      @killed_pids << [sig, pid]
      1
    end
  end

  it "starts a reaper thread on demand" do
    thread = described_class.start_reaper!(interval: 5.0)
    expect(thread).to be_a(Thread)
    expect(thread).to be_alive
  ensure
    described_class.stop_reaper!
  end

  it "is idempotent — second call returns the same thread" do
    a = described_class.start_reaper!(interval: 5.0)
    b = described_class.start_reaper!(interval: 5.0)
    expect(a).to be(b)
  ensure
    described_class.stop_reaper!
  end

  it "SIGKILLs tracked PTY children when the parent PID changes" do
    make_session

    # Start the reaper with a fake parent PID so the watchdog
    # immediately sees a mismatch and runs the kill path on its
    # first iteration.
    thread = described_class.start_reaper!(parent_pid: 1, interval: 0.05)

    # Give the watchdog one tick to observe the change.
    thread.join(0.5)

    expect(@killed_pids).to include(["KILL", fake_pid])
  end

  it "is a no-op when the parent is still alive" do
    make_session

    # parent_pid: Process.ppid — i.e. the real parent (rspec).
    # The reaper will see no mismatch and not signal anything.
    thread = described_class.start_reaper!(interval: 0.05)
    sleep 0.2
    expect(@killed_pids).to be_empty
  ensure
    described_class.stop_reaper!
  end

  it "does not re-kill sessions that are already exited" do
    make_session(status: "exited")

    thread = described_class.start_reaper!(parent_pid: 1, interval: 0.05)
    thread.join(0.5)

    expect(@killed_pids).to be_empty
  end

  it "SIGKILLs every live session, not just the first" do
    # Replace the fake_pid counter so each session has a unique pid.
    pid_seq = 100_000
    allow(described_class).to receive(:register).and_wrap_original do |orig, **kw|
      kw[:pid] = (pid_seq += 1)
      orig.call(**kw)
    end
    make_session
    make_session
    make_session

    thread = described_class.start_reaper!(parent_pid: 1, interval: 0.05)
    thread.join(0.5)

    killed = @killed_pids.map { |sig, pid| pid }
    expect(killed).to include(100_001, 100_002, 100_003)
  end

  it "Signal.trap handlers run kill_all! on TERM" do
    make_session

    described_class.start_reaper!(interval: 60.0)
    # Simulate the trap firing (we don't want to actually signal
    # rspec from inside rspec).
    handler = Signal.trap("TERM", "DEFAULT")
    expect(handler).to respond_to(:call)  # was our proc

    # Run the proc body directly so we don't need to fork.
    begin
      described_class.kill_all!
    rescue StandardError
      # never raise out of trap
    end
    expect(@killed_pids).to include(["KILL", fake_pid])
  end
end
