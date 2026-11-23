# frozen_string_literal: true

require "open3"

RSpec.describe "Git panel diff stream batching" do
  it "mounts file sections in batches instead of all at once" do
    script = File.expand_path("../../support/git_panel_stream_batch_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
