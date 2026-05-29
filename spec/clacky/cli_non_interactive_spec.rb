# frozen_string_literal: true

require "spec_helper"
require "clacky/cli"
require "clacky/plain_ui_controller"

RSpec.describe "CLI --message / -i non-interactive mode" do
  let(:cli) { Clacky::CLI.new }

  def call_run_non_interactive(agent, message, images, agent_config, session_manager)
    cli.send(:run_non_interactive, agent, message, images, agent_config, session_manager)
  end


  # Capture stdout and stderr helper to eliminate boilerplate
  def capture_stdio
    stdout = StringIO.new
    stderr = StringIO.new
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = stdout
    $stderr = stderr
    begin
      yield
      [stdout.string, stderr.string]
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end
  end

  let(:agent) { instance_double(Clacky::Agent, to_session_data: {}, history: [], rename: nil) }
  let(:agent_config) { Clacky::AgentConfig.new }
  let(:session_manager) { nil }

  before do
    allow(cli).to receive(:options).and_return(json: false)
  end

  describe "image path validation" do
    it "exits with status 1 for a missing image file" do
      allow(agent).to receive(:instance_variable_set)

      expect {
        call_run_non_interactive(agent, "hello", ["/nonexistent/image.png"], agent_config, session_manager)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "passes existing image paths to agent.run" do
      Tempfile.create(["test_image", ".png"]) do |f|
        f.write("\x89PNG") # minimal PNG header
        f.flush

        allow(agent).to receive(:instance_variable_set)
        allow(agent).to receive(:run)

        expect(agent).to receive(:run).with("describe this", files: [{ name: File.basename(f.path), mime_type: "image/png", path: f.path }])

        # exit(0) will raise SystemExit — catch it
        expect {
          call_run_non_interactive(agent, "describe this", [f.path], agent_config, session_manager)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end
    end

    it "passes empty images array when no images given" do
      allow(agent).to receive(:instance_variable_set)
      allow(agent).to receive(:run)

      expect(agent).to receive(:run).with("hello", files: [])

      expect {
        call_run_non_interactive(agent, "hello", [], agent_config, session_manager)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it "forces permission_mode to :auto_approve" do
      allow(agent).to receive(:instance_variable_set)
      allow(agent).to receive(:run)

      agent_config.permission_mode = :confirm_safes

      expect {
        call_run_non_interactive(agent, "hello", [], agent_config, session_manager)
      }.to raise_error(SystemExit)

      expect(agent_config.permission_mode).to eq(:auto_approve)
    end
  end

  describe "JSON mode (--json)" do
    before do
      allow(cli).to receive(:options).and_return(json: true)
      allow(agent).to receive(:instance_variable_set)
      allow(agent).to receive(:working_dir).and_return("/dummy")
      allow(agent).to receive(:total_tasks).and_return(1)
      allow(agent).to receive(:total_cost).and_return(0.0005)
    end

    it "outputs NDJSON events on success and saves session" do
      allow(agent).to receive(:run)

      session_mgr = double("SessionManager")
      expect(session_mgr).to receive(:save).with(anything)

      stdout, _ = capture_stdio do
        expect {
          call_run_non_interactive(agent, "hello", [], agent_config, session_mgr)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end

      lines = stdout.strip.split("\n").map { |l| JSON.parse(l) }
      expect(lines.first["type"]).to eq("system")
      expect(lines.last["type"]).to eq("done")
      expect(lines.last["total_cost"]).to eq(0.0005)
    end

    it "emits error event and saves session on early validation failure" do
      allow(agent).to receive(:to_session_data).with(status: :error, error_message: anything).and_return(stats: { last_status: "error" })

      session_mgr = double("SessionManager")
      expect(session_mgr).to receive(:save).with(hash_including(stats: hash_including(last_status: "error")))

      stdout, _ = capture_stdio do
        expect {
          call_run_non_interactive(agent, "hello", ["/nonexistent/image.png"], agent_config, session_mgr)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      lines = stdout.strip.split("\n").map { |l| JSON.parse(l) }
      expect(lines.any? { |l| l["type"] == "error" && l["message"].include?("File not found") }).to be true
      expect(lines.last["status"]).to eq("idle")
    end

    it "emits interrupted event and saves session on AgentInterrupted" do
      allow(agent).to receive(:run).and_raise(Clacky::AgentInterrupted.new("interrupted"))
      allow(agent).to receive(:to_session_data).with(status: :interrupted).and_return(stats: { last_status: "interrupted" })

      session_mgr = double("SessionManager")
      expect(session_mgr).to receive(:save).with(hash_including(stats: hash_including(last_status: "interrupted")))

      stdout, _ = capture_stdio do
        expect {
          call_run_non_interactive(agent, "hello", [], agent_config, session_mgr)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      lines = stdout.strip.split("\n").map { |l| JSON.parse(l) }
      expect(lines.any? { |l| l["type"] == "interrupted" }).to be true
      expect(lines.last["status"]).to eq("idle")
    end

    it "emits events in precise sequence: system -> working -> update_sessionbar -> idle -> done on success" do
      allow(agent).to receive(:run)

      session_mgr = double("SessionManager")
      expect(session_mgr).to receive(:save).with(anything)

      stdout, _ = capture_stdio do
        expect {
          call_run_non_interactive(agent, "hello", [], agent_config, session_mgr)
        }.to raise_error(SystemExit)
      end

      lines = stdout.strip.split("\n").map { |l| JSON.parse(l) }
      types = lines.map { |l| l["type"] }
      
      expect(types[0]).to eq("system")
      
      # Should contain working status update
      working_idx = lines.find_index { |l| l["type"] == "session_update" && l["status"] == "working" }
      expect(working_idx).not_to be_nil

      # Should contain sessionbar update after working status
      sessionbar_idx = lines.find_index { |l| l["type"] == "session_update" && l["tasks"] == 1 }
      expect(sessionbar_idx).not_to be_nil
      expect(sessionbar_idx).to be > working_idx

      # Should contain idle status update
      idle_idx = lines.find_index { |l| l["type"] == "session_update" && l["status"] == "idle" }
      expect(idle_idx).not_to be_nil
      expect(idle_idx).to be > sessionbar_idx

      # Done should be the last event
      expect(types.last).to eq("done")
    end

    it "early validation failure in JSON mode does NOT emit working or system status" do
      allow(agent).to receive(:to_session_data).with(status: :error, error_message: anything).and_return(stats: { last_status: "error" })

      session_mgr = double("SessionManager")
      expect(session_mgr).to receive(:save).with(anything)

      stdout, _ = capture_stdio do
        expect {
          call_run_non_interactive(agent, "hello", ["/nonexistent/image.png"], agent_config, session_mgr)
        }.to raise_error(SystemExit)
      end

      lines = stdout.strip.split("\n").map { |l| JSON.parse(l) }
      has_working = lines.any? { |l| l["type"] == "session_update" && l["status"] == "working" }
      expect(has_working).to be false
      has_system = lines.any? { |l| l["type"] == "system" }
      expect(has_system).to be false
    end

  end

  describe "Plain mode regression" do
    it "saves session on success and outputs plain text" do
      allow(agent).to receive(:instance_variable_set)
      allow(agent).to receive(:run)

      session_mgr = double("SessionManager")
      expect(session_mgr).to receive(:save).with(anything)

      stdout, _ = capture_stdio do
        expect {
          call_run_non_interactive(agent, "hello", [], agent_config, session_mgr)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end

      expect(stdout).not_to include('{"type":')
    end

    it "saves session on early failure and outputs to stderr" do
      allow(agent).to receive(:instance_variable_set)
      allow(agent).to receive(:to_session_data).with(status: :error, error_message: anything).and_return(stats: { last_status: "error" })

      session_mgr = double("SessionManager")
      expect(session_mgr).to receive(:save).with(hash_including(stats: hash_including(last_status: "error")))

      stdout, stderr = capture_stdio do
        expect {
          call_run_non_interactive(agent, "hello", ["/nonexistent/image.png"], agent_config, session_mgr)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(stdout).to be_empty
      expect(stderr).to include("Error: File not found")
    end

    it "saves session on AgentInterrupted and outputs to stderr" do
      allow(agent).to receive(:instance_variable_set)
      allow(agent).to receive(:run).and_raise(Clacky::AgentInterrupted.new("interrupted"))
      allow(agent).to receive(:to_session_data).with(status: :interrupted).and_return(stats: { last_status: "interrupted" })

      session_mgr = double("SessionManager")
      expect(session_mgr).to receive(:save).with(hash_including(stats: hash_including(last_status: "interrupted")))

      stdout, stderr = capture_stdio do
        expect {
          call_run_non_interactive(agent, "hello", [], agent_config, session_mgr)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(stdout).to be_empty
      expect(stderr).to include("Interrupted")
    end
  end
end
