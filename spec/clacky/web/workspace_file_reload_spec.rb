# frozen_string_literal: true

require "open3"

RSpec.describe "Web workspace file viewer reload" do
  it "refetches open tabs after AI edits instead of showing stale content" do
    script = File.expand_path("../../support/workspace_file_reload_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
