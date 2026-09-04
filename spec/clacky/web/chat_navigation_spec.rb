# frozen_string_literal: true

require "open3"

RSpec.describe "Chat navigation interactions" do
  it "passes the navigation and history-window runtime regressions" do
    script = File.expand_path("../../support/chat_navigation_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
