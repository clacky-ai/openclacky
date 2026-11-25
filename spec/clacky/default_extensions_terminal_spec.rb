# frozen_string_literal: true

require "spec_helper"
require "base64"
require "webrick"
require File.expand_path("../../lib/clacky/default_extensions/terminal/api/handler.rb", __dir__)

RSpec.describe "Terminal panel extension" do
  ext_root = File.expand_path("../../lib/clacky/default_extensions", __dir__)
  ext_dir  = File.join(ext_root, "terminal")
  runtime  = Clacky::Extensions::Terminal::Runtime

  class FrameSink
    def initialize
      @frames = []
      @mutex  = Mutex.new
    end

    def send_json(frame)
      @mutex.synchronize { @frames << frame }
    end

    def frames(type = nil)
      @mutex.synchronize { type ? @frames.select { |f| f[:type] == type } : @frames.dup }
    end

    def output
      frames("ext.terminal.output").map { |f| Base64.decode64(f[:data]) }.join
    end
  end

  def wait_until(timeout: 15)
    deadline = Time.now + timeout
    until Time.now > deadline
      return true if yield
      sleep 0.02
    end
    false
  end

  def builtin_root
    File.expand_path("../../lib/clacky/default_extensions", __dir__)
  end

  describe "manifest" do
    let(:tmp) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmp) if Dir.exist?(tmp) }

    def load_with(switches)
      allow(Clacky::ExtensionLoader).to receive(:ext_switch_state).and_return(switches)
      Clacky::ExtensionLoader.load_all(
        layers: { builtin: builtin_root, installed: tmp, local: tmp }, force: true
      )
    end

    it "ships switched off, so it contributes no panel and no api" do
      result = load_with({})

      expect(result.errors).to be_empty
      container = result.containers["terminal"]
      expect(container).not_to be_nil
      expect(container.dig(:raw, "enabled_by_default")).to be false
      expect(result.panels.select { |p| p.ext_id == "terminal" }).to be_empty
      expect(result.api.select { |u| u.ext_id == "terminal" }).to be_empty
    end

    it "contributes the aside panel and the api once the user turns it on" do
      result = load_with("terminal" => true)

      expect(result.errors).to be_empty
      panel = result.panels.find { |p| p.ext_id == "terminal" }
      expect(panel).not_to be_nil
      expect(panel.id).to eq("terminal")
      expect(panel.spec["view"]).to eq("panels/terminal/view.js")
      expect(File.file?(File.join(ext_dir, panel.spec["view"]))).to be true

      api = result.api.find { |u| u.ext_id == "terminal" }
      expect(api).not_to be_nil
      expect(File.file?(api.spec["handler_abs"])).to be true
    end
  end

  describe "http routes" do
    let(:res) { WEBrick::HTTPResponse.new(WEBrick::Config::HTTP) }
    let(:sink) { FrameSink.new }

    before do
      Clacky::ApiExtension.reset_registry!
      allow(Clacky::ApiExtensionLoader).to receive(:ensure_fresh)
      TerminalExtension.ext_id = "terminal"
      TerminalExtension.ext_dir = ext_dir
      TerminalExtension.meta = {}
      Clacky::ApiExtension.register("terminal", TerminalExtension)
    end

    after { runtime.close_all! }

    def post_open(remote_ip, body = {})
      req = double("req",
        path: "/api/ext/terminal/open",
        request_method: "POST",
        body: JSON.generate(body),
        query: {},
        remote_ip: remote_ip)
      Clacky::Server::ApiExtensionDispatcher.handle(req, res, http_server: nil)
    end

    it "refuses to spawn a shell for a client that is not on this machine" do
      post_open("10.1.2.3")
      expect(res.status).to eq(403)
      expect(runtime.list).to be_empty
    end

    it "opens a shell in the caller's session directory" do
      home = Dir.mktmpdir
      begin
        server = Object.new
        session_manager = double("session manager", load: { working_dir: home })
        server.instance_variable_set(:@session_manager, session_manager)

        req = double("req",
          path: "/api/ext/terminal/open",
          request_method: "POST",
          body: JSON.generate(session_id: "s1", cols: 90, rows: 30),
          query: {},
          remote_ip: "127.0.0.1")
        Clacky::Server::ApiExtensionDispatcher.handle(req, res, http_server: server)

        expect(res.status).to eq(200)
        payload = JSON.parse(res.body)
        expect(payload["cwd"]).to eq(home)
        expect(payload["term_id"]).not_to be_nil
        expect(File.realpath(payload["cwd"])).to eq(File.realpath(home))
      ensure
        FileUtils.remove_entry(home)
      end
    end
  end

  describe "runtime" do
    let(:workdir) { Dir.mktmpdir }

    after do
      runtime.close_all!
      FileUtils.remove_entry(workdir) if Dir.exist?(workdir)
    end

    it "streams what the shell prints" do
      session = runtime.open(cwd: workdir, cols: 100, rows: 40)
      sink = FrameSink.new
      session.attach(sink)

      ready = sink.frames("ext.terminal.ready").first
      expect(ready[:term_id]).to eq(session.id)
      expect(ready[:status]).to eq("running")
      expect(ready[:cwd]).to eq(workdir)

      session.write("echo terminal-mark-4711\r")
      expect(wait_until { sink.output.include?("terminal-mark-4711") }).to be true
    end

    it "replays buffered output to a client that attaches late" do
      session = runtime.open(cwd: workdir)
      first = FrameSink.new
      session.attach(first)
      session.write("echo late-join-88\r")
      expect(wait_until { first.output.include?("late-join-88") }).to be true

      late = FrameSink.new
      session.attach(late)
      replay = Base64.decode64(late.frames("ext.terminal.ready").first[:replay])
      expect(replay).to include("late-join-88")
    end

    it "propagates the client window size to the pty" do
      session = runtime.open(cwd: workdir, cols: 80, rows: 24)
      sink = FrameSink.new
      session.attach(sink)

      expect(session.resize(100, 40)).to be true
      session.write("stty size\r")
      expect(wait_until { sink.output.include?("40 100") }).to be true
    end

    it "notifies subscribers once the shell exits" do
      session = runtime.open(cwd: workdir)
      sink = FrameSink.new
      session.attach(sink)

      session.close!
      expect(wait_until { !sink.frames("ext.terminal.exit").empty? }).to be true
      expect(sink.frames("ext.terminal.exit").first[:term_id]).to eq(session.id)
      expect(session.running?).to be false
    end

    it "rejects a single input burst larger than the cap" do
      session = runtime.open(cwd: workdir)
      oversized = "x" * (runtime::MAX_INPUT_BYTES + 1)
      expect(session.write(oversized)).to be false
      expect(session.write("echo still-alive\r")).to be true
    end

    it "makes room by evicting the least recently used idle shell" do
      stub_const("Clacky::Extensions::Terminal::Runtime::MAX_SESSIONS", 2)
      first = runtime.open(cwd: workdir)
      runtime.open(cwd: workdir)

      third = runtime.open(cwd: workdir)

      expect(runtime.find(first.id)).to be_nil
      expect(runtime.find(third.id)).to be(third)
      expect(first.running?).to be false
    end

    it "raises instead of evicting a shell a client is still using" do
      stub_const("Clacky::Extensions::Terminal::Runtime::MAX_SESSIONS", 2)
      runtime.open(cwd: workdir).attach(FrameSink.new)
      runtime.open(cwd: workdir).attach(FrameSink.new)

      expect { runtime.open(cwd: workdir) }
        .to raise_error(Clacky::Extensions::Terminal::Runtime::CapacityError)
    end

    it "reaps a shell nobody attached to for too long" do
      t0 = 1_000.0
      allow(runtime).to receive(:now).and_return(t0)
      session = runtime.open(cwd: workdir)

      allow(runtime).to receive(:now).and_return(t0 + runtime::UNATTACHED_TTL + 1)
      runtime.sweep!

      expect(runtime.find(session.id)).to be_nil
      expect(session.running?).to be false
    end
  end

  describe "websocket frames" do
    let(:workdir) { Dir.mktmpdir }
    let(:sink) { FrameSink.new }
    let(:session) { runtime.open(cwd: workdir, cols: 100, rows: 40) }

    after do
      runtime.close_all!
      FileUtils.remove_entry(workdir) if Dir.exist?(workdir)
    end

    def send_frame(type, payload = {})
      TerminalExtension.on_ws_event(sink, { "type" => type }.merge(payload))
    end

    it "attaches, feeds input and reports the exit through frames alone" do
      expect(send_frame("ext.terminal.attach", "term_id" => session.id)).to be true
      expect(sink.frames("ext.terminal.ready").length).to eq(1)

      send_frame("ext.terminal.input", "term_id" => session.id, "data" => "echo framed-ok\r")
      expect(wait_until { sink.output.include?("framed-ok") }).to be true

      send_frame("ext.terminal.close", "term_id" => session.id)
      expect(wait_until { !sink.frames("ext.terminal.exit").empty? }).to be true
    end

    it "applies a resize sent as a frame" do
      send_frame("ext.terminal.attach", "term_id" => session.id)
      send_frame("ext.terminal.resize", "term_id" => session.id, "cols" => 100, "rows" => 40)
      send_frame("ext.terminal.input", "term_id" => session.id, "data" => "stty size\r")

      expect(wait_until { sink.output.include?("40 100") }).to be true
    end

    it "stops pushing output once the client detaches" do
      send_frame("ext.terminal.attach", "term_id" => session.id)
      send_frame("ext.terminal.detach", "term_id" => session.id)

      before_count = sink.frames("ext.terminal.output").length
      send_frame("ext.terminal.input", "term_id" => session.id, "data" => "echo after-detach\r")
      sleep 0.3

      expect(sink.frames("ext.terminal.output").length).to eq(before_count)
      expect(session.running?).to be true
    end

    it "drops a connection on socket close" do
      session.attach(sink)

      TerminalExtension.on_ws_close(sink)
      before_count = sink.frames("ext.terminal.output").length
      session.write("echo after-close\r")
      sleep 0.3

      expect(sink.frames("ext.terminal.output").length).to eq(before_count)
    end

    it "leaves frames of other owners to the dispatcher" do
      expect(send_frame("message", "term_id" => session.id)).to be false
      expect(send_frame("ext.terminal.unknown", "term_id" => session.id)).to be false
      expect(send_frame("ext.other.thing")).to be false
    end

    it "ignores a frame for a shell that is already gone" do
      expect(send_frame("ext.terminal.input", "term_id" => "nope", "data" => "x\r")).to be true
      expect(sink.frames("ext.terminal.output")).to be_empty
    end

    it "tells a client that the shell it wants to reattach is gone" do
      send_frame("ext.terminal.attach", "term_id" => "nope")

      gone = sink.frames("ext.terminal.gone").first
      expect(gone).not_to be_nil
      expect(gone[:term_id]).to eq("nope")
    end
  end
end
