# frozen_string_literal: true

require "open3"

RSpec.describe "Web session error history" do
  it "renders persisted failures without duplicating the current error" do
    script = File.expand_path("../../support/session_error_history_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
