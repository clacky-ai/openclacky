# frozen_string_literal: true

require "spec_helper"
require "clacky/server/server_master"

RSpec.describe Clacky::Server::Master do
  subject(:master) { described_class.new(host: "127.0.0.1", port: 7070) }

  let(:socket) { double("socket", fileno: 12) }

  before do
    allow(socket).to receive(:close_on_exec=)
    master.instance_variable_set(:@socket, socket)
    allow(master).to receive(:spawn).and_return(12_345)
  end

  def capture_spawn_environment
    captured = nil
    allow(master).to receive(:spawn) do |env, *_args|
      captured = env
      12_345
    end
    master.spawn_worker
    captured
  end

  # Standalone flock holder script (see spec/support/lock_holder.rb). It is
  # launched detached via /bin/sh so it is reparented to init: POSIX record
  # locks are associated with the process, and a direct child of the rspec
  # process would inherit its lock relationships and could not model a second
  # server started independently from another shell.
  LOCK_HOLDER_SCRIPT = File.expand_path("../../support/lock_holder.rb", __dir__)

  # flock contention is per-process, so tests that need a contending owner use
  # a real detached process holding the exclusive lock. The holder records its
  # readiness and its real pid in files (nothing is inherited over a pipe).
  def spawn_lock_holder(dir, ignore_termsig: false)
    require "shellwords"
    lock_path = File.join(dir, "server.lock")
    ready = File.join(dir, "holder.ready")
    pidfile = File.join(dir, "holder.pid")
    [ready, pidfile].each { |p| File.delete(p) if File.exist?(p) }

    args = [lock_path, ready, pidfile, ignore_termsig ? "ignore-term" : "normal"]
    shell =
      "exec env -u RUBYOPT -u BUNDLE_GEMFILE -u BUNDLE_PATH " \
      "-u BUNDLE_BIN_PATH -u BUNDLE_APP_CONFIG " \
      "#{RbConfig.ruby.shellescape} #{LOCK_HOLDER_SCRIPT.shellescape} " \
      "#{args.map(&:shellescape).join(' ')} </dev/null >/dev/null 2>&1 &"
    launcher = spawn("/bin/sh", "-c", shell, pgroup: true)
    Process.waitpid(launcher)

    deadline = Time.now + 5
    sleep 0.05 until File.exist?(ready) || Time.now > deadline
    status = File.exist?(ready) ? File.read(ready) : "missing"
    raise "lock holder failed to start (#{status})" unless status == "locked"
    sleep 0.05 until File.exist?(pidfile) || Time.now > deadline
    File.read(pidfile).to_i
  end

  def kill_silently(pid, force: false)
    return unless pid
    Process.kill(force ? "KILL" : "TERM", pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  ensure
    Process.waitpid(pid) rescue nil # ECHILD when reparented to init
  end

  # True when a fresh, unrelated process can take the exclusive lock at once.
  def lock_free_from_child?(dir = config_dir)
    pid = spawn(
      RbConfig.ruby, "-e",
      "require 'fcntl'; f = File.open(File.join(ARGV[0], 'server.lock'), File::RDWR); " \
      "exit(f.flock(File::LOCK_EX | File::LOCK_NB) == 0 ? 0 : 1)",
      dir,
      out: File::NULL, err: File::NULL
    )
    Process.waitpid(pid)
    $?.exitstatus.zero?
  end

  it "inherits CLACKY_LICENSE_SERVER when no source has been saved" do
    allow(Clacky::AgentConfig).to receive(:load).and_return(
      Clacky::AgentConfig.new(clacky_license_server: nil)
    )

    env = capture_spawn_environment

    expect(env).not_to have_key("CLACKY_LICENSE_SERVER")
  end

  it "injects a saved private source into the Worker" do
    allow(Clacky::AgentConfig).to receive(:load).and_return(
      Clacky::AgentConfig.new(clacky_license_server: "https://enterprise.example.com")
    )

    env = capture_spawn_environment

    expect(env["CLACKY_LICENSE_SERVER"]).to eq("https://enterprise.example.com")
  end

  it "removes an inherited override when the official source is saved" do
    allow(Clacky::AgentConfig).to receive(:load).and_return(
      Clacky::AgentConfig.new(clacky_license_server: Clacky::PlatformHttpClient::PRIMARY_HOST)
    )

    env = capture_spawn_environment

    expect(env).to include("CLACKY_LICENSE_SERVER" => nil)
  end

  it "does not fall back from the requested port in strict mode" do
    master = described_class.new(host: "127.0.0.1", port: 7070, strict_port: true)
    allow(master).to receive(:kill_existing_master)
    allow(master).to receive(:acquire_instance_lock!)
    allow(master).to receive(:remove_pid_file)
    expect(master).to receive(:bind_with_fallback).with("127.0.0.1", 7070, max_port: 7070).and_return(nil)
    expect { master.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end

  it "keeps the default fallback range without strict mode" do
    allow(master).to receive(:kill_existing_master)
    allow(master).to receive(:acquire_instance_lock!)
    allow(master).to receive(:remove_pid_file)
    expect(master).to receive(:bind_with_fallback).with("127.0.0.1", 7070, max_port: 7075).and_return(nil)
    expect { master.run }.to raise_error(SystemExit)
  end

  it "allows the old master its worker cleanup budget before escalating" do
    Dir.mktmpdir do |dir|
      allow(Dir).to receive(:tmpdir).and_return(dir)
      File.write(File.join(dir, "clacky-master-7070.pid"), "12345")
      allow(master).to receive(:port_busy?).and_return(false)
      allow(Process).to receive(:kill).with("TERM", 12_345)
      expect(Process).not_to receive(:kill).with("KILL", 12_345)
      allow(master).to receive(:process_dead?).with(12_345).and_return(false, false, true, true)
      allow(master).to receive(:kill_process_group!).with(12_345)
      allow(Time).to receive(:now).and_return(Time.at(0), Time.at(6), Time.at(11))
      allow(master).to receive(:sleep)
      master.kill_existing_master
    end
  end

  it "removes a PID file pointing at a dead PID without signalling it" do
    Dir.mktmpdir do |dir|
      allow(Dir).to receive(:tmpdir).and_return(dir)
      path = File.join(dir, "clacky-master-7070.pid")
      File.write(path, "999")
      allow(master).to receive(:port_busy?).and_return(false)
      allow(master).to receive(:process_dead?).with(999).and_return(true)
      expect(Process).not_to receive(:kill)
      master.kill_existing_master
      expect(File.exist?(path)).to eq(false)
    end
  end

  it "does not delete a replacement master's PID file" do
    Dir.mktmpdir do |dir|
      allow(Dir).to receive(:tmpdir).and_return(dir)
      File.write(master.pid_file_path, "12345")
      master.remove_pid_file
      expect(File.read(master.pid_file_path)).to eq("12345")
    end
  end

  it "cleans the worker group even when the worker exited gracefully" do
    master.instance_variable_set(:@worker_pid, 12_345)
    expect(Process).to receive(:kill).with("TERM", -12_345).ordered
    allow(Process).to receive(:waitpid2).with(12_345, Process::WNOHANG).and_return([12_345, nil])
    expect(Process).to receive(:kill).with("KILL", -12_345).ordered
    allow(socket).to receive(:close)
    expect { master.shutdown }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
  end

  describe "single-instance lock" do
    let(:config_dir) { Dir.mktmpdir }

    before do
      stub_const("Clacky::AgentConfig::CONFIG_DIR", config_dir)
    end

    after do
      FileUtils.remove_entry(config_dir) rescue nil
    end

    it "acquires the data-directory lock when it is free" do
      master.send(:acquire_instance_lock!)

      expect(File.exist?(master.send(:instance_lock_path))).to eq(true)
      # A separate process cannot take the same exclusive lock.
      expect(lock_free_from_child?).to eq(false)
    end

    it "writes its own pid and port as best-effort lock metadata" do
      master.send(:acquire_instance_lock!)
      master.send(:write_lock_metadata)

      contents = File.read(master.send(:instance_lock_path))
      expect(contents).to include(Process.pid.to_s)
      expect(contents).to include("port=7070")
    end

    it "takes over from the live lock holder and acquires once it shuts down" do
      # flock contention is per-process, so the holder must be a real child.
      holder = spawn_lock_holder(config_dir)
      allow(master).to receive(:process_dead?).with(holder).and_return(false, true)

      expect { master.send(:acquire_instance_lock!) }.not_to raise_error
      # A separate process must now be blocked from taking the lock (proves we
      # own it cross-process; a same-process fd cannot prove POSIX ownership).
      expect(lock_free_from_child?).to eq(false)
    ensure
      kill_silently(holder, force: true)
    end

    it "refuses to start when the live lock holder cannot be stopped" do
      # The lock stays held by another real process while our handover attempt
      # fails (e.g. EPERM on another user's process): we must refuse to start
      # rather than silently coexist. A real child is required because flock
      # contention is only visible across separate processes.
      holder = spawn_lock_holder(config_dir, ignore_termsig: true)
      allow(master).to receive(:stop_clacky_pid)
      allow(master).to receive(:sleep)
      stub_const("Clacky::Server::Master::WORKER_GRACE_EXIT_SECONDS", 0)

      expect { master.send(:acquire_instance_lock!) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(lock_free_from_child?(config_dir)).to be(false)
    ensure
      kill_silently(holder, force: true)
    end

    it "recovers a stale lock whose recorded holder is gone" do
      File.write(master.send(:instance_lock_path), "4242")
      expect(master).not_to receive(:stop_clacky_pid)
      allow(master).to receive(:process_dead?).with(4242).and_return(true)

      master.send(:acquire_instance_lock!)
      expect(File.read(master.send(:instance_lock_path))).to eq("4242") # content untouched
    end

    it "releases the lock on exit so another instance can take it" do
      master.send(:acquire_instance_lock!)
      expect(lock_free_from_child?).to eq(false)

      master.send(:release_instance_lock)
      expect(lock_free_from_child?).to eq(true)
    end

    it "runs the lock gate before binding on startup" do
      allow(master).to receive(:kill_existing_master)
      allow(master).to receive(:remove_pid_file)
      expect(master).to receive(:acquire_instance_lock!).ordered
      expect(master).to receive(:bind_with_fallback).ordered.and_return(nil)
      allow(master).to receive(:release_instance_lock)
      expect { master.run }.to raise_error(SystemExit)
    end
  end

  describe "legacy Linux reclaim (/proc, no external commands)" do
    it "is a no-op off Linux even when the port is busy" do
      stub_const("RUBY_PLATFORM", "x86_64-darwin22")
      expect(master).not_to receive(:port_busy?)
      master.send(:reclaim_legacy_linux_master, 7070)
    end

    it "leaves a busy port owned by a non-Clacky program untouched" do
      stub_const("RUBY_PLATFORM", "x86_64-linux")
      allow(master).to receive(:port_busy?).with(7070).and_return(true)
      allow(master).to receive(:linux_clacky_listeners).with(7070).and_return([])
      expect(master).not_to receive(:stop_clacky_pid)
      master.send(:reclaim_legacy_linux_master, 7070)
    end

    it "stops a legacy Clacky listener identified via /proc" do
      stub_const("RUBY_PLATFORM", "x86_64-linux")
      allow(master).to receive(:port_busy?).with(7070).and_return(true, false)
      allow(master).to receive(:linux_clacky_listeners).with(7070).and_return([777])
      expect(master).to receive(:stop_clacky_pid).with(777, port: 7070)
      master.send(:reclaim_legacy_linux_master, 7070)
    end

    it "maps LISTEN socket inodes to a port from /proc/net/tcp" do
      Dir.mktmpdir do |root|
        net_dir = File.join(root, "net")
        FileUtils.mkdir_p(net_dir)
        File.write(File.join(net_dir, "tcp"),
          "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" \
          "   0: 0100007F:1B9E 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0\n" \
          "   1: 0100007F:1B9F 0A00007F:C290 01 00000000:00000000 00:00000000 00000000     0        0 67890 1 0000000000000000 100 0 0 10 0\n")
        allow(Dir).to receive(:glob).and_call_original
        allow(Dir).to receive(:glob).with("/proc/net/tcp*").and_return([File.join(net_dir, "tcp")])
        expect(master.send(:linux_listen_inodes, 7070)).to eq(["12345"])
      end
    end

    it "recognizes a `clacky server` cmdline and rejects unrelated ones" do
      allow(File).to receive(:read).with("/proc/777/cmdline").and_return(
        "/usr/bin/ruby\u0000/root/.gem/bin/openclacky\u0000server\u0000--port\u00007070\u0000"
      )
      allow(File).to receive(:read).with("/proc/888/cmdline").and_return(
        "/usr/bin/nginx: worker process\u0000"
      )
      expect(master.send(:clacky_cmdline?, 777)).to eq(true)
      expect(master.send(:clacky_cmdline?, 888)).to eq(false)
    end
  end
end
