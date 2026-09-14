# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "rbconfig"
require "clacky/acp/process_transport"

RSpec.describe Clacky::Acp::ProcessTransport do
  FAKE_AGENT = File.expand_path("../../support/fake_acp_agent.rb", __dir__)

  let(:tmpdir) { Dir.mktmpdir("acp-process-transport") }
  let(:events) { Queue.new }

  after do
    @transport&.stop
    FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
  end

  def start_transport(args: [], env: {}, cwd: nil, max_message_bytes: 1024, stderr_bytes: 256)
    @transport = described_class.new(
      name: "fake-agent",
      argv: [RbConfig.ruby, FAKE_AGENT] + args,
      env: env,
      cwd: cwd,
      max_message_bytes: max_message_bytes,
      stderr_bytes: stderr_bytes
    )
    @transport.on_message { |message| events << message }
    @transport.start
  end

  def send_request(id, method, params = {})
    @transport.send_message(
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    )
  end

  def next_event(timeout: 3)
    Timeout.timeout(timeout) do
      loop do
        event = events.pop
        return event if !block_given? || yield(event)
      end
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  it "uses exact argv, a controlled environment, cwd, and a separate process group" do
    marker = File.join(tmpdir, "must-not-exist")
    literal_arg = "literal value; touch #{marker}"

    ClimateControl.modify(
      "ACP_PARENT_SECRET" => "must-not-leak",
      "ACP_PARENT_VISIBLE" => "inherited"
    ) do
      start_transport(
        args: [literal_arg, "second argument"],
        env: {
          "ACP_PARENT_SECRET" => nil,
          "ACP_CHILD_VALUE" => "configured"
        },
        cwd: tmpdir
      )
      send_request(
        1,
        "fake/inspect",
        "env_keys" => %w[ACP_PARENT_SECRET ACP_PARENT_VISIBLE ACP_CHILD_VALUE]
      )
      response = next_event { |event| event["id"] == 1 }
      result = response.fetch("result")

      expect(result["argv"]).to eq([literal_arg, "second argument"])
      expect(File.realpath(result["cwd"])).to eq(File.realpath(tmpdir))
      expect(result["env"]).to eq(
        "ACP_PARENT_SECRET" => nil,
        "ACP_PARENT_VISIBLE" => nil,
        "ACP_CHILD_VALUE" => "configured"
      )
      expect(result["pgid"]).to eq(result["pid"])
      expect(result["pgid"]).not_to eq(Process.getpgrp)
      expect(File).not_to exist(marker)
    end
  end

  it "writes one JSON line and emits parsed JSON messages" do
    start_transport

    send_request(2, "initialize")
    response = next_event { |event| event["id"] == 2 }

    expect(response.dig("result", "protocolVersion")).to eq(1)
    expect(response.dig("result", "agentInfo", "name")).to eq("fake-acp-agent")
    expect(@transport.alive?).to be(true)
  end

  it "reports malformed JSON as a structured error and keeps reading" do
    start_transport

    send_request(3, "fake/malformed")
    error = next_event { |event| event.key?("__transport_error__") }
    response = next_event { |event| event["id"] == 3 }

    expect(error["__transport_error__"]).to include(
      "code" => "malformed_json"
    )
    expect(error["error"]).to match(/invalid JSON/)
    expect(response.dig("result", "sent")).to be(true)
  end

  it "reports an oversized line once, discards it, and resumes at the next line" do
    start_transport(max_message_bytes: 256)

    send_request(4, "fake/oversized", "bytes" => 2048)
    error = next_event { |event| event.key?("__transport_error__") }
    response = next_event { |event| event["id"] == 4 }

    expect(error["__transport_error__"]).to include(
      "code" => "message_too_large",
      "max_bytes" => 256
    )
    expect(response.dig("result", "sent")).to be(true)
  end

  it "emits a closed event with the child exit status on EOF" do
    start_transport

    send_request(5, "fake/exit", "status" => 7)
    closed = next_event { |event| event["__transport_closed__"] }

    expect(closed["exit_status"]).to eq(7)
    expect(@transport.alive?).to be(false)
  end

  it "bounds and redacts sensitive stderr diagnostics" do
    start_transport(stderr_bytes: 256)
    diagnostic = ("prefix-" * 100) +
      " OPENAI_API_KEY=super-secret" +
      " sk-live-secret-token" +
      " Authorization: Bearer bearer-secret" +
      ' access_token="access-secret" tail-marker'

    send_request(6, "fake/stderr", "text" => diagnostic)
    next_event { |event| event["id"] == 6 }

    deadline = Time.now + 2
    sleep(0.01) until @transport.stderr_tail.include?("tail-marker") || Time.now >= deadline
    tail = @transport.stderr_tail

    expect(tail.bytesize).to be <= 256
    expect(tail).to include("tail-marker", "[REDACTED]")
    expect(tail).not_to include(
      "super-secret",
      "sk-live-secret-token",
      "bearer-secret",
      "access-secret"
    )
    expect(@transport.stderr_tail(bytes: 40).bytesize).to be <= 40
  end

  it "closes stdin before terminating the owned process group" do
    marker = File.join(tmpdir, "shutdown-order")
    start_transport(
      env: {
        "FAKE_ACP_SHUTDOWN_MARKER" => marker,
        "FAKE_ACP_LINGER_ON_EOF" => "1"
      }
    )
    send_request(7, "fake/spawn_child")
    child_pid = next_event { |event| event["id"] == 7 }.dig("result", "pid")

    @transport.stop

    expect(File.readlines(marker, chomp: true)).to eq(%w[stdin_closed term])
    deadline = Time.now + 2
    sleep(0.01) while process_alive?(child_pid) && Time.now < deadline
    expect(process_alive?(child_pid)).to be(false)
    expect(@transport.alive?).to be(false)
  end

  it "clears process ownership so repeated stop cannot signal an old process group" do
    start_transport
    wait_thread = @transport.instance_variable_get(:@wait_thread)
    expect(wait_thread).not_to be_nil

    @transport.stop

    expect(@transport.instance_variable_get(:@wait_thread)).to be_nil
    expect(@transport.instance_variable_get(:@pgid)).to be_nil
    expect { @transport.stop }.not_to raise_error
  end

  it "does not emit a stale close from an earlier process generation after restart" do
    start_transport
    old_wait_thread = @transport.instance_variable_get(:@wait_thread)
    old_generation = @transport.instance_variable_get(:@generation)

    @transport.stop
    next_event { |event| event["__transport_closed__"] }
    @transport.start

    @transport.send(:emit_closed, old_wait_thread, old_generation)
    expect(events).to be_empty

    send_request(81, "initialize")
    response = next_event { |event| event["id"] == 81 }
    expect(response.dig("result", "protocolVersion")).to eq(1)
  end

  it "force-kills the process group when the child ignores TERM" do
    marker = File.join(tmpdir, "forced-shutdown")
    start_transport(
      env: {
        "FAKE_ACP_SHUTDOWN_MARKER" => marker,
        "FAKE_ACP_LINGER_ON_EOF" => "1",
        "FAKE_ACP_IGNORE_TERM" => "1"
      }
    )
    send_request(8, "initialize")
    next_event { |event| event["id"] == 8 }

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @transport.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    expect(File.readlines(marker, chomp: true)).to eq(%w[stdin_closed term])
    expect(elapsed).to be < 3
    expect(@transport.alive?).to be(false)
  end
end
