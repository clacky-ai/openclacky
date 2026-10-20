# frozen_string_literal: true

require "open3"

RSpec.describe "Web sidebar session promotion" do
  it "promotes snapshots that sort inside the loaded pages" do
    script = File.expand_path("../../support/session_list_promotion_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
