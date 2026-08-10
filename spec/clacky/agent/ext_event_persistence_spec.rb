# frozen_string_literal: true

require "spec_helper"

RSpec.describe "extension custom events" do
  # UIInterface is a module, not a class — include it and stub the rest of the
  # show_* surface so replay can run against a bare recorder.
  class RecordingUI
    include Clacky::UIInterface

    attr_reader :emitted

    def initialize
      @emitted = []
    end

    def emit(type, **data)
      @emitted << { type: type, data: data }
    end

    def method_missing(name, *args, **kwargs); end
    def respond_to_missing?(name, include_private = false)
      true
    end
  end

  let(:ui) { RecordingUI.new }
  let(:client) { instance_double(Clacky::Client) }

  def build_agent(with_ui = ui)
    Clacky::Agent.new(client, Clacky::AgentConfig.new, working_dir: Dir.pwd, ui: with_ui,
                      profile: "coding", session_id: Clacky::SessionManager.generate_id,
                      source: :manual)
  end

  let(:agent) do
    build_agent.tap { |a| a.history.append({ role: "user", content: "hello" }) }
  end

  describe "#emit_event" do
    it "pushes to the UI in real time" do
      agent.emit_event("ext.demo.tick", n: 1)

      expect(ui.emitted).to eq([{ type: "ext.demo.tick", data: { n: 1 } }])
    end

    it "is transient by default so progress chatter never touches session.json" do
      agent.emit_event("ext.demo.tick", n: 1)

      expect(agent.history.to_a.last[:ext_events]).to be_nil
    end

    it "records onto the current message when persist: true" do
      agent.emit_event("ext.demo.milestone", label: "done", persist: true)

      expect(agent.history.to_a.last[:ext_events])
        .to eq([{ type: "ext.demo.milestone", data: { label: "done" } }])
    end

    it "keeps persisted events out of the LLM payload" do
      agent.emit_event("ext.demo.milestone", label: "done", persist: true)

      expect(agent.history.to_api.last.keys).not_to include(:ext_events)
    end

    it "rejects event types outside the ext.* namespace" do
      expect { agent.emit_event("assistant_message", content: "spoof") }
        .to raise_error(ArgumentError, /ext\.<extension>\.<event>/)
    end

    it "still emits live when there is no message to anchor to" do
      fresh = build_agent

      expect { fresh.emit_event("ext.demo.early", persist: true) }.not_to raise_error
      expect(ui.emitted.size).to eq(1)
    end

    it "drops the oldest event once the per-message cap is reached" do
      cap = Clacky::MessageHistory::MAX_EXT_EVENTS_PER_MESSAGE
      (cap + 5).times { |i| agent.emit_event("ext.demo.tick", n: i, persist: true) }

      stored = agent.history.to_a.last[:ext_events]
      expect(stored.size).to eq(cap)
      expect(stored.first[:data][:n]).to eq(5)
      expect(stored.last[:data][:n]).to eq(cap + 4)
    end

    it "refuses payloads too large for session.json" do
      agent.emit_event("ext.demo.blob", blob: "x" * 9000, persist: true)

      expect(agent.history.to_a.last[:ext_events]).to be_nil
    end
  end

  describe "replay after reload" do
    it "re-emits events recorded on a user message" do
      agent.emit_event("ext.demo.on_user", v: 1, persist: true)
      restored = reload(agent)

      restored.replay_history(ui_for_replay = RecordingUI.new)
      expect(ui_for_replay.emitted).to include({ type: "ext.demo.on_user", data: { v: 1 } })
    end

    it "re-emits events recorded on a tool result message" do
      agent.history.append({ role: "tool", content: "result", tool_call_id: "c1" })
      agent.emit_event("ext.demo.on_tool", v: 2, persist: true)
      restored = reload(agent)

      restored.replay_history(ui_for_replay = RecordingUI.new)
      expect(ui_for_replay.emitted).to include({ type: "ext.demo.on_tool", data: { v: 2 } })
    end

    it "survives a full serialize → JSON → restore round trip" do
      agent.emit_event("ext.demo.persisted", label: "kept", persist: true)

      raw = JSON.parse(JSON.generate(agent.to_session_data), symbolize_names: true)
      restored = build_agent
      restored.restore_session(raw)

      restored.replay_history(ui_for_replay = RecordingUI.new)
      expect(ui_for_replay.emitted).to include({ type: "ext.demo.persisted", data: { label: "kept" } })
    end
  end

  describe "surviving compression into a chunk MD" do
    let(:writer) do
      Class.new do
        include Clacky::Agent::MessageCompressorHelper
        def truncate_content(s, max_length: 500)
          s.to_s[0, max_length]
        end
        def format_message_content(c)
          c.to_s
        end
        public :render_message_sections
      end.new
    end

    let(:reader) do
      Class.new do
        include Clacky::Agent::SessionSerializer
        public :extract_ext_events_from_text
      end.new
    end

    def sections_of(md)
      md.split(/^(?=## |### )/).reject { |s| s.strip.empty? }
    end

    it "writes persisted events into the archived markdown" do
      md = writer.render_message_sections([
        { role: "user", content: "go",
          ext_events: [{ type: "ext.demo.kept", data: { n: 1 } }] }
      ]).join("\n")

      expect(md).to include('_Ext events: ext.demo.kept | {"n":1}_')
    end

    it "reads them back out of the archived markdown" do
      md = writer.render_message_sections([
        { role: "assistant", content: "working",
          ext_events: [{ type: "ext.demo.a", data: { i: 1 } },
                       { type: "ext.demo.b", data: { i: 2 } }] }
      ]).join("\n")

      _text, events = reader.extract_ext_events_from_text(sections_of(md).first.strip)

      expect(events).to eq([
        { type: "ext.demo.a", data: { "i" => 1 } },
        { type: "ext.demo.b", data: { "i" => 2 } }
      ])
    end

    it "strips the marker line from the replayed conversation text" do
      md = writer.render_message_sections([
        { role: "user", content: "visible text",
          ext_events: [{ type: "ext.demo.kept", data: {} }] }
      ]).join("\n")

      text, = reader.extract_ext_events_from_text(sections_of(md).first.strip)

      expect(text).to include("visible text")
      expect(text).not_to include("_Ext events:")
    end

    it "keeps each message's events with that message" do
      md = writer.render_message_sections([
        { role: "user", content: "ask",
          ext_events: [{ type: "ext.demo.first", data: {} }] },
        { role: "tool", name: "gen", content: "done",
          ext_events: [{ type: "ext.demo.second", data: {} }] }
      ]).join("\n")

      per_section = sections_of(md).map { |s| reader.extract_ext_events_from_text(s.strip).last }

      expect(per_section[0].map { |e| e[:type] }).to eq(["ext.demo.first"])
      expect(per_section[1].map { |e| e[:type] }).to eq(["ext.demo.second"])
    end

    it "leaves messages without events untouched" do
      md = writer.render_message_sections([{ role: "user", content: "plain" }]).join("\n")

      expect(md).not_to include("_Ext events:")
    end
  end

  describe "separator ambiguity between \";\" and JSON payloads" do
    let(:writer) do
      Class.new do
        include Clacky::Agent::MessageCompressorHelper
        def truncate_content(s, max_length: 500)
          s.to_s[0, max_length]
        end
        def format_message_content(c)
          c.to_s
        end
        public :render_message_sections
      end.new
    end

    let(:reader) do
      Class.new do
        include Clacky::Agent::SessionSerializer
        public :extract_ext_events_from_text, :parse_tool_calls_line
      end.new
    end

    def ext_events_of(md)
      reader.extract_ext_events_from_text(md).last
    end

    def tool_calls_of(md)
      raw = md[/_Tool calls:\s*(.+?)_\s*$/m, 1]
      reader.parse_tool_calls_line(raw)
    end

    it "round-trips an ext event whose data contains semicolons" do
      prompt = "step one; step two; step three"
      md = writer.render_message_sections([
        { role: "assistant", content: "designing",
          ext_events: [{ type: "ext.eazo.design_start", data: { prompt: prompt } }] }
      ]).join("\n")

      events = ext_events_of(md)

      expect(events.size).to eq(1)
      expect(events.first[:type]).to eq("ext.eazo.design_start")
      expect(events.first[:data]["prompt"]).to eq(prompt)
    end

    it "keeps both events when the first payload contains a semicolon" do
      md = writer.render_message_sections([
        { role: "assistant", content: "x",
          ext_events: [{ type: "ext.demo.a", data: { cmd: "a; b" } },
                       { type: "ext.demo.b", data: { i: 2 } }] }
      ]).join("\n")

      events = ext_events_of(md)

      expect(events.map { |e| e[:type] }).to eq(["ext.demo.a", "ext.demo.b"])
      expect(events.first[:data]["cmd"]).to eq("a; b")
    end

    it "round-trips tool call args containing semicolons verbatim" do
      command = "pkill -f server 2>/dev/null; nohup ruby app.rb & sleep 2; curl localhost"
      md = writer.render_message_sections([
        { role: "assistant", content: "running",
          tool_calls: [{ function: { name: "terminal",
                                     arguments: { command: command }.to_json } }] }
      ]).join("\n")

      calls = tool_calls_of(md)

      expect(calls.size).to eq(1)
      expect(calls.first[:name]).to eq("terminal")
      expect(calls.first[:args]["command"]).to eq(command)
    end

    it "separates two tool calls when the second payload contains a semicolon" do
      md = writer.render_message_sections([
        { role: "assistant", content: "running",
          tool_calls: [{ function: { name: "file_reader", arguments: { path: "a.rb" }.to_json } },
                       { function: { name: "terminal", arguments: { command: "cd x; ls" }.to_json } }] }
      ]).join("\n")

      calls = tool_calls_of(md)

      expect(calls.map { |c| c[:name] }).to eq(["file_reader", "terminal"])
      expect(calls.last[:args]["command"]).to eq("cd x; ls")
    end

    it "handles nested braces and quotes inside tool call args" do
      js = '(async () => { const r = await fetch("/a?x=1;y=2"); return {ok: r.ok} })()'
      md = writer.render_message_sections([
        { role: "assistant", content: "eval",
          tool_calls: [{ function: { name: "browser", arguments: { js: js }.to_json } }] }
      ]).join("\n")

      calls = tool_calls_of(md)

      expect(calls.size).to eq(1)
      expect(calls.first[:args]["js"]).to eq(js)
    end

    it "walks past nested JSON objects instead of stopping at the first brace" do
      args = { opts: { retries: 2, tags: ["a;b"] }, cmd: "run; done" }
      md = writer.render_message_sections([
        { role: "assistant", content: "eval",
          tool_calls: [{ function: { name: "terminal", arguments: args.to_json } }] }
      ]).join("\n")

      calls = tool_calls_of(md)

      expect(calls.size).to eq(1)
      expect(calls.first[:args]["opts"]).to eq({ "retries" => 2, "tags" => ["a;b"] })
      expect(calls.first[:args]["cmd"]).to eq("run; done")
    end

    it "ignores unbalanced braces that live inside JSON string values" do
      command = "echo '{' > /tmp/x; cat /tmp/x"
      md = writer.render_message_sections([
        { role: "assistant", content: "eval",
          tool_calls: [{ function: { name: "terminal",
                                     arguments: { command: command }.to_json } }] }
      ]).join("\n")

      calls = tool_calls_of(md)

      expect(calls.size).to eq(1)
      expect(calls.first[:args]["command"]).to eq(command)
    end

    it "treats escaped quotes as literal, not as string boundaries" do
      command = 'echo "{" > /tmp/marker; ls'
      md = writer.render_message_sections([
        { role: "assistant", content: "eval",
          tool_calls: [{ function: { name: "terminal",
                                     arguments: { command: command }.to_json } }] }
      ]).join("\n")

      calls = tool_calls_of(md)

      expect(calls.size).to eq(1)
      expect(calls.first[:args]["command"]).to eq(command)
    end

    it "still parses the legacy comma-separated names-only format" do
      calls = reader.parse_tool_calls_line("file_reader, terminal, write")

      expect(calls.map { |c| c[:name] }).to eq(["file_reader", "terminal", "write"])
      expect(calls.map { |c| c[:args] }).to all(eq({}))
    end

    it "does not invent ext events from entries without a JSON payload" do
      _text, events = reader.extract_ext_events_from_text("_Ext events: bare.type.no.payload_")

      expect(events).to be_empty
    end
  end

  def reload(agent)
    build_agent.tap { |a| a.restore_session(agent.to_session_data) }
  end
end
