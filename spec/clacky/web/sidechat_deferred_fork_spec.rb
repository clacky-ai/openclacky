# frozen_string_literal: true

require "open3"

RSpec.describe "Side chat panel fork timing" do
  it "replaces the branch on the first message, not when the quote is clicked" do
    script = File.expand_path("../../support/sidechat_deferred_fork_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
