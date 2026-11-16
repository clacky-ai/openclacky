# frozen_string_literal: true

require "open3"

RSpec.describe "Folded group status dot" do
  it "clears the running dot once every session in the group has finished" do
    script = File.expand_path("../../support/folded_group_status_dot_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
