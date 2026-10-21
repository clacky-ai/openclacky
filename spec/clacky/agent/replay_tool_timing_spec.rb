# frozen_string_literal: true

# Per-tool execution timing. The data layer stamps created_at on the assistant
# message carrying tool_calls and on each tool-result message (see agent.rb
# observe() / MessageHistory). History replay must annotate those timestamps
# onto the emitted tool_call / tool_result events via annotate_last_event so
# the frontend can compute each tool's duration after a reload — without
# changing the UiInterface show_tool_* signatures.
RSpec.describe "replay_history tool timing" do
  let(:ui) do
    Class.new do
      def initialize
        @events = []
      end

      def show_tool_call(name, args)
        @events << { type: :call, name: name, args: args, created_at: nil }
      end

      def show_tool_result(result, ui: nil)
        @events << { type: :result, result: result, ui: ui, created_at: nil }
      end

      # Mirrors HistoryCollector#annotate_last_event: stamp the event just emitted.
      def annotate_last_event(created_at: nil)
        return unless created_at
        last = @events.last
        return unless last
        last[:created_at] = created_at
      end

      def calls
        @events.select { |e| e[:type] == :call }
      end

      def results
        @events.select { |e| e[:type] == :result }
      end

      def method_missing(_name, *_args, **_kwargs); end

      def respond_to_missing?(_name, _include_private = false)
        true
      end
    end.new
  end

  let(:registry) do
    reg = Clacky::ToolRegistry.new
    reg.register(Clacky::Tools::Terminal.new)
    reg
  end

  let(:host) do
    Class.new do
      include Clacky::Agent::SessionSerializer

      def initialize(registry)
        @tool_registry = registry
      end

      def replay(msgs, ui)
        msgs.each { |m| _replay_single_message(m, ui) }
      end
    end.new(registry)
  end

  def assistant_call(id, name, created_at:)
    { role: "assistant", content: "", created_at: created_at,
      tool_calls: [{ id: id, type: "function",
                     function: { name: name, arguments: "{}" } }] }
  end

  it "annotates the assistant created_at onto the tool_call (OpenAI format)" do
    host.replay([
      assistant_call("call_1", "terminal", created_at: 1000.0),
      { role: "tool", tool_call_id: "call_1", content: JSON.generate(output: "hi"), created_at: 1003.2 }
    ], ui)

    expect(ui.calls.last[:created_at]).to eq(1000.0)
    expect(ui.results.last[:created_at]).to eq(1003.2)
  end

  it "annotates the tool-result created_at for an Anthropic-format result block" do
    host.replay([
      assistant_call("toolu_1", "terminal", created_at: 2000.0),
      { role: "user", created_at: 2005.5,
        content: [{ type: "tool_result", tool_use_id: "toolu_1", content: JSON.generate(output: "ok") }] }
    ], ui)

    expect(ui.calls.last[:created_at]).to eq(2000.0)
    expect(ui.results.last[:created_at]).to eq(2005.5)
  end

  it "skips annotate when created_at is missing (legacy messages)" do
    expect {
      host.replay([
        assistant_call("call_2", "terminal", created_at: nil),
        { role: "tool", tool_call_id: "call_2", content: JSON.generate(output: "hi") }
      ], ui)
    }.not_to raise_error

    expect(ui.calls.last[:created_at]).to be_nil
    expect(ui.results.last[:created_at]).to be_nil
  end
end
