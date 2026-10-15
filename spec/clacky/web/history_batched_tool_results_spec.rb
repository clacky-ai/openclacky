# frozen_string_literal: true

require "open3"

RSpec.describe "Web history replay of batched tool calls" do
  it "pairs each replayed tool result with its own call in order" do
    script = File.expand_path("../../support/history_batched_tool_results_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
