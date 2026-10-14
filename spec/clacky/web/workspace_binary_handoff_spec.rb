# frozen_string_literal: true

require "open3"

RSpec.describe "Web workspace binary handoff and media preview" do
  it "previews browser media and opens unsupported binary files with the OS default application" do
    script = File.expand_path("../../support/workspace_binary_handoff_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
