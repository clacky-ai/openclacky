# frozen_string_literal: true

RSpec.describe "Historical message editing while a session is running" do
  let(:sessions_js) do
    File.read(File.expand_path("../../../lib/clacky/web/sessions.js", __dir__))
  end

  it "hides every edit button while running and restores only the last one afterward" do
    expect(sessions_js).to include(
      'btn.style.display = !running && i === btns.length - 1 ? "" : "none";'
    )
    expect(sessions_js).to include("_refreshEditButtons(RenderTarget.outer(), status);")
  end

  it "guards both entering and submitting edit mode against status races" do
    expect(sessions_js).to include(
      'if (_activeSessionIsRunning() || el.classList.contains("editing")) return;'
    )
    expect(sessions_js).to match(
      /function _submitEdit\(el, newContent\).*?if \(_activeSessionIsRunning\(\)\)/m
    )
  end
end
