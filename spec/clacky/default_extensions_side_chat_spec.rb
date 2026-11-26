# frozen_string_literal: true

require "spec_helper"
require "webrick"
require File.expand_path("../../lib/clacky/default_extensions/side-chat/api/handler.rb", __dir__)

RSpec.describe "Side chat panel extension" do
  ext_root = File.expand_path("../../lib/clacky/default_extensions", __dir__)
  ext_dir  = File.join(ext_root, "side-chat")
  runtime  = Clacky::Extensions::SideChat::Runtime

  class SideChatFrameSink
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
  end

  def wait_until(timeout: 5)
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

  # A stand-in for a real Agent: the extension only needs the conversation, a
  # fork and the two billing entry points.
  def build_parent(history: Clacky::MessageHistory.new([]), fork: nil, session_id: "session-1")
    fork ||= double("fork", history: Clacky::MessageHistory.new([]), run: { iterations: 1, total_cost_usd: 0.01 })
    double("parent",
      session_id: session_id,
      history: history,
      config: double("config", effective_model_name: "test-model"),
      fork_subagent: fork,
      persist_billing_record: nil,
      absorb_subagent_cost: 0.0)
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

    it "ships switched on, so it contributes the panel and the api unprompted" do
      result = load_with({})

      expect(result.errors).to be_empty
      container = result.containers["side-chat"]
      expect(container).not_to be_nil
      expect(container.dig(:raw, "enabled_by_default")).to be true
      expect(result.panels.count { |p| p.ext_id == "side-chat" }).to eq(1)
      expect(result.api.count { |u| u.ext_id == "side-chat" }).to eq(1)
    end

    it "drops the panel and the api once the user turns it off" do
      result = load_with("side-chat" => false)

      expect(result.errors).to be_empty
      expect(result.panels.select { |p| p.ext_id == "side-chat" }).to be_empty
      expect(result.api.select { |u| u.ext_id == "side-chat" }).to be_empty
    end

    it "contributes the aside panel and the api" do
      result = load_with("side-chat" => true)

      expect(result.errors).to be_empty
      panel = result.panels.find { |p| p.ext_id == "side-chat" }
      expect(panel).not_to be_nil
      expect(panel.id).to eq("side-chat")
      expect(File.file?(File.join(ext_dir, panel.spec["view"]))).to be true

      api = result.api.find { |u| u.ext_id == "side-chat" }
      expect(api).not_to be_nil
      expect(File.file?(api.spec["handler_abs"])).to be true
    end
  end

  describe "runtime" do
    after { runtime.reset! }

    it "forks the parent conversation so the branch can answer about it" do
      history = Clacky::MessageHistory.new([{ role: "user", content: "hello" }])
      fork = double("fork", history: Clacky::MessageHistory.new([]), run: { iterations: 1 })
      parent = build_parent(history: history, fork: fork)

      chat = runtime.open(parent_id: "session-1", parent: parent)

      expect(parent).to have_received(:fork_subagent)
        .with(model: nil, forbidden_tools: runtime::FORBIDDEN_TOOLS)
      expect(fork.history.to_a.size).to eq(1)
      expect(chat.parent_id).to eq("session-1")
      expect(chat.model).to eq("test-model")
    end

    it "denies the tools that would let a read-only branch touch the world" do
      %w[write edit terminal ask_user todo_manager].each do |name|
        expect(runtime::FORBIDDEN_TOOLS).to include(name)
      end
      expect(runtime::FORBIDDEN_TOOLS).not_to include("file_reader", "grep", "web_search")
    end

    it "teaches the branch that it is a read-only side channel" do
      fork = double("fork", history: Clacky::MessageHistory.new([]), run: { iterations: 1 })
      parent = build_parent(fork: fork)

      runtime.open(parent_id: "session-1", parent: parent)

      appended = fork.history.to_a.last
      expect(appended[:role]).to eq("user")
      expect(appended[:system_injected]).to be true
      expect(appended[:content]).to include("SIDE CHAT")
      expect(appended[:content]).to include("read-only")
    end

    it "reuses the branch that is already attached to the session" do
      parent = build_parent
      first = runtime.open(parent_id: "session-1", parent: parent)
      again = runtime.open(parent_id: "session-1", parent: parent)

      expect(again).to be(first)
      expect(parent).to have_received(:fork_subagent).once
    end

    it "re-forks when the panel asks for a fresh branch" do
      parent = build_parent
      first = runtime.open(parent_id: "session-1", parent: parent)
      second = runtime.open(parent_id: "session-1", parent: parent, fresh: true)

      expect(second).not_to be(first)
      expect(runtime.find(first.id)).to be_nil
      expect(parent).to have_received(:fork_subagent).twice
    end

    it "streams a turn over the panel frames" do
      parent = build_parent
      chat = runtime.open(parent_id: "session-1", parent: parent)
      sink = SideChatFrameSink.new
      chat.attach(sink)

      expect(sink.frames("ext.side_chat.attached").first[:chat_id]).to eq(chat.id)

      expect(chat.ask(text: "what does this mean?")).to eq(:started)
      expect(wait_until { !sink.frames("ext.side_chat.turn").empty? }).to be true

      types = sink.frames.map { |f| f[:type] }
      expect(types[0, 3]).to eq(["ext.side_chat.attached", "ext.side_chat.busy", "ext.side_chat.user"])
      expect(sink.frames("ext.side_chat.busy").first[:chat_id]).to eq(chat.id)
      user = sink.frames("ext.side_chat.user").first
      expect(user[:text]).to eq("what does this mean?")
      expect(sink.frames("ext.side_chat.turn").first[:state]).to eq("done")
      expect(chat.running?).to be false
    end

    it "forwards the thinking line so the panel can show progress" do
      fork = double("fork", history: Clacky::MessageHistory.new([]), run: { iterations: 1 })
      chat = runtime.open(parent_id: "session-1", parent: build_parent(fork: fork))
      sink = SideChatFrameSink.new
      chat.attach(sink)

      fork.instance_variable_get(:@ui).show_progress("思考中", progress_type: "thinking", metadata: { tokens: 12 })

      progress = sink.frames("ext.side_chat.event").map { |f| f[:event] }.find { |e| e[:type] == "progress" }
      expect(progress).not_to be_nil
      expect(progress[:message]).to eq("思考中")
      expect(progress[:phase]).to eq("active")
      expect(progress[:progress_type]).to eq("thinking")
      expect(progress[:metadata]).to eq(tokens: 12)
      expect(progress[:started_at]).to be_a(Integer)
    end

    it "refuses a second question while the branch is still thinking" do
      gate = Queue.new
      fork = double("fork", history: Clacky::MessageHistory.new([]))
      allow(fork).to receive(:run) do
        gate.pop
        { iterations: 1 }
      end
      chat = runtime.open(parent_id: "session-1", parent: build_parent(fork: fork))

      expect(chat.ask(text: "first")).to eq(:started)
      expect(chat.ask(text: "second")).to eq(:busy)
      gate << :go
      expect(wait_until { !chat.running? }).to be true
    end

    it "closes the turn even when a second stop lands while it is finishing" do
      finishing = Queue.new
      release   = Queue.new
      reads     = 0
      counted   = Mutex.new
      # The turn thread reads the clock twice: at the start of the turn, and in
      # the ensure — the window between the rescue and the flag being cleared.
      # Parking it on the second read is what makes that window reachable.
      allow(runtime).to receive(:now).and_wrap_original do |original|
        value = original.call
        if Thread.current != Thread.main && counted.synchronize { reads += 1 } == 2
          finishing << :here
          release.pop
        end
        value
      end

      fork = double("fork", history: Clacky::MessageHistory.new([]), run: { iterations: 1 })
      allow(fork).to receive(:run) { raise Clacky::AgentInterrupted, "Interrupted by user" }
      chat = runtime.open(parent_id: "session-1", parent: build_parent(fork: fork))
      sink = SideChatFrameSink.new
      chat.attach(sink)

      expect(chat.ask(text: "why?")).to eq(:started)
      expect(finishing.pop).to eq(:here)
      chat.interrupt
      release << :go

      expect(wait_until { !chat.running? }).to be true
      expect(sink.frames("ext.side_chat.turn").first[:state]).to eq("interrupted")
    end

    it "bills the model calls into the parent session instead of dropping them" do
      fork = double("fork", history: Clacky::MessageHistory.new([]), run: { iterations: 1 })
      parent = build_parent(fork: fork)
      runtime.open(parent_id: "session-1", parent: parent)

      ui = fork.instance_variable_get(:@ui)
      ui.show_token_usage(cost: 0.02, prompt_tokens: 120, completion_tokens: 40, cache_read: 10, cache_write: 5)

      expect(parent).to have_received(:persist_billing_record).with(
        { prompt_tokens: 120, completion_tokens: 40, cache_read_input_tokens: 10, cache_creation_input_tokens: 5 },
        0.02,
        model: "test-model"
      )
      expect(parent).to have_received(:absorb_subagent_cost).with({ total_cost_usd: 0.02 }, notify_ui: true)
    end

    it "keeps only the panel's own events off the wire" do
      fork = double("fork", history: Clacky::MessageHistory.new([]), run: { iterations: 1 })
      parent = build_parent(fork: fork)
      chat = runtime.open(parent_id: "session-1", parent: parent)
      sink = SideChatFrameSink.new
      chat.attach(sink)

      ui = fork.instance_variable_get(:@ui)
      ui.show_assistant_message("hello there", files: [])
      ui.show_token_usage(cost: 0.001, prompt_tokens: 1, completion_tokens: 1)
      ui.show_complete(iterations: 1, cost: 0.001)

      events = sink.frames("ext.side_chat.event").map { |f| f[:event][:type] }
      expect(events).to eq(["assistant_message"])
    end

    it "caps the number of live branches and refuses instead of dropping one in use" do
      stub_const("Clacky::Extensions::SideChat::Runtime::MAX_CHATS", 2)
      parent = build_parent
      runtime.open(parent_id: "session-1", parent: parent).attach(SideChatFrameSink.new)
      runtime.open(parent_id: "session-2", parent: parent).attach(SideChatFrameSink.new)

      expect { runtime.open(parent_id: "session-3", parent: parent) }
        .to raise_error(runtime::CapacityError)
      expect(parent).to have_received(:fork_subagent).twice
    end

    it "re-forks its own branch even when every slot is taken" do
      stub_const("Clacky::Extensions::SideChat::Runtime::MAX_CHATS", 1)
      parent = build_parent
      first = runtime.open(parent_id: "session-1", parent: parent)

      second = runtime.open(parent_id: "session-1", parent: parent, fresh: true)

      expect(runtime.find(second.id)).to be(second)
      expect(runtime.find(first.id)).to be_nil
    end

    it "leaves one branch when two fresh opens race, and shuts the loser down" do
      runtime.open(parent_id: "session-1", parent: build_parent)

      forked  = Queue.new
      release = Queue.new
      fork = double("fork", history: Clacky::MessageHistory.new([]), run: { iterations: 1 })
      parent = build_parent
      allow(parent).to receive(:fork_subagent) do
        forked << :in_fork
        release.pop
        fork
      end

      # Both opens sit in the fork before either registers — the window a
      # close-then-register sequence leaves open.
      threads = Array.new(2) do
        Thread.new { runtime.open(parent_id: "session-1", parent: parent, fresh: true) }
      end
      2.times { forked.pop }
      2.times { release << :go }

      chats = threads.map(&:value)
      survivors = chats.select { |chat| runtime.find(chat.id) }

      expect(survivors.size).to eq(1)
      expect((chats - survivors).first.ask(text: "anyone there?")).to eq(:closed)
    end

    it "reaps a branch nobody has looked at for an hour" do
      t0 = 1_000.0
      allow(runtime).to receive(:now).and_return(t0)
      chat = runtime.open(parent_id: "session-1", parent: build_parent)

      allow(runtime).to receive(:now).and_return(t0 + runtime::IDLE_TTL + 1)
      runtime.open(parent_id: "session-2", parent: build_parent)

      expect(runtime.find(chat.id)).to be_nil
    end

    it "survives a parent that is mid-turn by repairing the copied tool call" do
      history = Clacky::MessageHistory.new([
        { role: "user", content: "do it" },
        { role: "assistant", content: nil, tool_calls: [{ id: "call-1", function: { name: "file_reader", arguments: "{}" } }] }
      ])
      # fork_subagent deep-copies the history, dangling tool call included.
      fork = double("fork", history: Clacky::MessageHistory.new(history.to_a), run: { iterations: 1 })

      chat = runtime.open(parent_id: "session-1", parent: build_parent(history: history, fork: fork))

      expect(fork.history.to_a.size).to eq(2)
      expect(fork.history.to_a.map { |m| m[:role] }).to eq(%w[user user])
      expect(fork.history.to_a.last[:content]).to include("SIDE CHAT")
    end
  end

  describe "http routes" do
    let(:res) { WEBrick::HTTPResponse.new(WEBrick::Config::HTTP) }
    let(:parent) { build_parent }

    before do
      Clacky::ApiExtension.reset_registry!
      allow(Clacky::ApiExtensionLoader).to receive(:ensure_fresh)
      SideChatExtension.ext_id = "side-chat"
      SideChatExtension.ext_dir = ext_dir
      SideChatExtension.meta = {}
      Clacky::ApiExtension.register("side-chat", SideChatExtension)
    end

    after { runtime.reset! }

    def server_with(registry)
      server = Object.new
      server.instance_variable_set(:@registry, registry)
      server
    end

    def post(path, body, server)
      req = double("req",
        path: "/api/ext/side-chat#{path}",
        request_method: "POST",
        body: JSON.generate(body),
        query: {},
        remote_ip: "127.0.0.1")
      Clacky::Server::ApiExtensionDispatcher.handle(req, res, http_server: server)
    end

    it "opens a branch for a session that is live in the registry" do
      registry = double("registry", exist?: true, get: { agent: parent })
      post("/open", { session_id: "session-1" }, server_with(registry))

      expect(res.status).to eq(200)
      payload = JSON.parse(res.body)
      expect(payload.keys).to eq(["chat_id"])
      expect(payload["chat_id"]).not_to be_nil
    end

    it "restores a session that the registry has not loaded yet" do
      registry = double("registry")
      allow(registry).to receive(:exist?).with("session-1").and_return(false)
      allow(registry).to receive(:ensure).with("session-1")
      allow(registry).to receive(:get).with("session-1").and_return({ agent: parent })
      post("/open", { session_id: "session-1" }, server_with(registry))

      expect(res.status).to eq(200)
      expect(registry).to have_received(:ensure).with("session-1")
    end

    it "answers 404 for a session the registry does not know" do
      registry = double("registry", exist?: true, get: nil)
      post("/open", { session_id: "missing" }, server_with(registry))

      expect(res.status).to eq(404)
    end

    it "answers 400 without a session id" do
      post("/open", {}, server_with(double("registry")))

      expect(res.status).to eq(400)
    end

    it "answers 429 when every branch slot is taken by an open panel" do
      stub_const("Clacky::Extensions::SideChat::Runtime::MAX_CHATS", 1)
      runtime.open(parent_id: "session-1", parent: parent).attach(SideChatFrameSink.new)

      other = build_parent(session_id: "session-2")
      registry = double("registry", exist?: true, get: { agent: other })
      post("/open", { session_id: "session-2" }, server_with(registry))

      expect(res.status).to eq(429)
    end

    it "closes a branch on request" do
      chat = runtime.open(parent_id: "session-1", parent: parent)
      post("/close", { chat_id: chat.id }, server_with(double("registry")))

      expect(res.status).to eq(200)
      expect(runtime.find(chat.id)).to be_nil
    end
  end

  describe "websocket frames" do
    let(:sink) { SideChatFrameSink.new }
    let(:chat) { runtime.open(parent_id: "session-1", parent: build_parent) }

    before do
      Clacky::ApiExtension.reset_registry!
      SideChatExtension.ext_id = "side-chat"
      SideChatExtension.ext_dir = ext_dir
      SideChatExtension.meta = {}
      Clacky::ApiExtension.register("side-chat", SideChatExtension)
    end

    after { runtime.reset! }

    # Mirrors the server: the frame namespace is resolved back to a registered
    # extension before on_ws_event sees it (`ext.side_chat.*` → id "side-chat").
    def send_frame(type, payload = {})
      extension = Clacky::ApiExtension.ws_extension_for(type)
      return false unless extension

      extension.on_ws_event(sink, { "type" => type }.merge(payload))
    end

    it "resolves an underscore frame namespace to a hyphenated extension id" do
      expect(Clacky::ApiExtension.ws_extension_for("ext.side_chat.send")).to eq(SideChatExtension)
      expect(Clacky::ApiExtension.ws_extension_for("ext.side-chat.send")).to eq(SideChatExtension)
      expect(Clacky::ApiExtension.ws_extension_for("ext.other.send")).to be_nil
      expect(Clacky::ApiExtension.ws_extension_for("message")).to be_nil
    end

    it "attaches the socket to the branch" do
      expect(send_frame("ext.side_chat.attach", "chat_id" => chat.id)).to be true

      attached = sink.frames("ext.side_chat.attached").first
      expect(attached[:chat_id]).to eq(chat.id)
      expect(attached[:model]).to eq("test-model")
      expect(attached[:running]).to be false
      expect(chat.attached?).to be true
    end

    it "asks a question through the frame and reports the turn" do
      send_frame("ext.side_chat.attach", "chat_id" => chat.id)
      send_frame("ext.side_chat.send", "chat_id" => chat.id, "text" => "why?")

      expect(wait_until { !sink.frames("ext.side_chat.turn").empty? }).to be true
      expect(sink.frames("ext.side_chat.user").first[:text]).to eq("why?")
    end

    it "forwards staged quotes as injected context" do
      fork = double("fork", history: Clacky::MessageHistory.new([]), run: { iterations: 1 })
      own = runtime.open(parent_id: "session-9", parent: build_parent(fork: fork))
      send_frame("ext.side_chat.send",
        "chat_id" => own.id,
        "text" => "explain",
        "references" => [{ "label" => "Assistant · #3", "text" => "some excerpt" }])

      expect(wait_until { !own.running? }).to be true
      expect(fork).to have_received(:run).with(
        "explain",
        files: [],
        reference_contexts: [
          hash_including(type: "quote", text: "some excerpt", context: a_string_including("Quoted excerpt"))
        ]
      )
    end

    it "tells the panel when its branch is gone" do
      send_frame("ext.side_chat.attach", "chat_id" => "nope")

      expect(sink.frames("ext.side_chat.gone").first[:chat_id]).to eq("nope")
    end

    it "leaves frames of other owners to the dispatcher" do
      expect(send_frame("message", "chat_id" => chat.id)).to be false
      expect(send_frame("ext.side_chat.unknown", "chat_id" => chat.id)).to be false
      expect(send_frame("ext.terminal.attach", "term_id" => "x")).to be false
    end

    it "detaches every branch of a closing socket" do
      chat.attach(sink)
      SideChatExtension.on_ws_close(sink)

      expect(chat.attached?).to be false
    end
  end
end
