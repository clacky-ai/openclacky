# frozen_string_literal: true

RSpec.describe "Runtime event rendering" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:sessions) { File.read(File.join(web_dir, "sessions.js")) }
  let(:dispatcher) { File.read(File.join(web_dir, "ws-dispatcher.js")) }

  it "updates a keyed assistant stream instead of appending the final text twice" do
    expect(sessions).to include("appendAssistantMessage")
    expect(sessions).to match(/if \(delta\)[\s\S]*assistantStreams/)
    expect(sessions).to match(/assistantStreams\.delete\(messageId\)/)
    expect(sessions).to include("extraElement.remove()")
    expect(dispatcher).to include(
      "messageIds: ev.message_ids"
    )
  end

  it "uses tool call ids while retaining the positional fallback" do
    expect(dispatcher).to include(
      "Sessions.appendToolCall(ev.name, ev.args, ev.summary, ev.tool_call_id)"
    )
    expect(dispatcher).to include(
      "status: ev.status, exitCode: ev.exit_code"
    )
    expect(sessions).to include("toolCallId ? _findToolItemByCallId")
    expect(sessions).to include("ctx.item")
    expect(sessions).to include('status.className = `tool-item-status ${failed ? "err" : "ok"}`')
    expect(sessions).to include("result.formatted_output")
  end

  it "preserves structured tool UI alongside keyed runtime result metadata" do
    expect(dispatcher).to include(
      "status: ev.status, exitCode: ev.exit_code, ui: ev.ui || null"
    )
    expect(sessions).to include(
      "status: resultStatus = null,\n    exitCode = null,\n    ui = null"
    )
    expect(sessions).to include("stdout.innerHTML = _renderWebSearchResults(ui)")
    expect(sessions).to include(
      "status: ev.status,\n          exitCode: ev.exit_code,\n          ui: ev.ui"
    )
  end
end
