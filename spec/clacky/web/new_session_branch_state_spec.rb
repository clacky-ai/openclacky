# frozen_string_literal: true

require "open3"

RSpec.describe "Web new-session branch state" do
  it "caches the project branch, drops stale responses, and merges checkouts" do
    script = File.expand_path("../../support/new_session_branch_state_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
