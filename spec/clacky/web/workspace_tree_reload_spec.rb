# frozen_string_literal: true

require "open3"

RSpec.describe "Web workspace tree reload" do
  it "keeps the listing on screen and re-opens expanded folders after an agent task" do
    script = File.expand_path("../../support/workspace_tree_reload_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
