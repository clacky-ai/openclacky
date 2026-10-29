# frozen_string_literal: true

require "open3"

RSpec.describe "Web theme switch" do
  it "repaints every region in the same frame" do
    script = File.expand_path("../../support/theme_switch_sync_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
