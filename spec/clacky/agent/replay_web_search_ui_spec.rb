# frozen_string_literal: true

# web_search renders a structured result card in the live path (agent.rb passes
# `ui:` alongside the plain text). History replay must pass the same payload,
# otherwise reloading the page degrades the card to plain text (C-5797).
#
# The structured data is already on disk: web_search has no
# format_result_for_llm, so build_success_result persists the full result hash
# as JSON. Replay only has to parse it back and re-run the tool's ui_result.
RSpec.describe "replay_history web_search ui payload" do
  let(:ui) do
    Class.new do
      attr_reader :tool_results

      def initialize
        @tool_results = []
      end

      def show_tool_result(result, ui: nil)
        @tool_results << { result: result, ui: ui }
      end

      def method_missing(_name, *_args, **_kwargs); end

      def respond_to_missing?(_name, _include_private = false)
        true
      end
    end.new
  end

  let(:registry) do
    reg = Clacky::ToolRegistry.new
    reg.register(Clacky::Tools::WebSearch.new)
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

  let(:search_payload) do
    {
      query: "openclacky",
      results: [{ title: "OpenClacky", url: "https://example.com", snippet: "A gem" }],
      count: 1,
      provider: "parallel",
      error: nil
    }
  end

  def assistant_call(id, name)
    { role: "assistant", content: "", tool_calls: [{ id: id, type: "function",
                                                     function: { name: name, arguments: "{}" } }] }
  end

  it "rebuilds the structured card for an OpenAI-format tool result" do
    host.replay([
      assistant_call("call_1", "web_search"),
      { role: "tool", tool_call_id: "call_1", content: JSON.generate(search_payload) }
    ], ui)

    payload = ui.tool_results.last[:ui]
    expect(payload).to include(
      type: "web_search",
      query: "openclacky",
      count: 1,
      provider: "parallel"
    )
    expect(payload[:results].first).to include(title: "OpenClacky", url: "https://example.com")
  end

  it "rebuilds the structured card for an Anthropic-format tool result block" do
    host.replay([
      assistant_call("toolu_1", "web_search"),
      { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1",
                                  content: JSON.generate(search_payload) }] }
    ], ui)

    expect(ui.tool_results.last[:ui]).to include(type: "web_search", count: 1)
  end

  it "keeps the plain-text path for tools without a ui_result" do
    host.replay([
      assistant_call("call_2", "terminal"),
      { role: "tool", tool_call_id: "call_2", content: JSON.generate(output: "hi") }
    ], ui)

    expect(ui.tool_results.last[:ui]).to be_nil
  end

  it "passes the original text through unchanged alongside the ui payload" do
    content = JSON.generate(search_payload)
    host.replay([
      assistant_call("call_3", "web_search"),
      { role: "tool", tool_call_id: "call_3", content: content }
    ], ui)

    expect(ui.tool_results.last[:result]).to eq(content)
  end

  it "degrades to plain text when the stored content is not parseable JSON" do
    host.replay([
      assistant_call("call_4", "web_search"),
      { role: "tool", tool_call_id: "call_4", content: "{ not json" }
    ], ui)

    expect(ui.tool_results.last).to eq({ result: "{ not json", ui: nil })
  end

  it "degrades to plain text for legacy results with no matching tool call" do
    host.replay([
      { role: "tool", tool_call_id: "orphan", content: JSON.generate(search_payload) }
    ], ui)

    expect(ui.tool_results.last[:ui]).to be_nil
  end

  it "does not raise when the tool result carries no id at all" do
    expect {
      host.replay([{ role: "tool", content: "plain output" }], ui)
    }.not_to raise_error
    expect(ui.tool_results.last[:ui]).to be_nil
  end
end
