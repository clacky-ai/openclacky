# frozen_string_literal: true

require "open3"

RSpec.describe "Web aside fullscreen scroll position" do
  it "preserves the conversation reading anchor across fullscreen toggles" do
    script = File.expand_path("../../support/aside_fullscreen_scroll_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
