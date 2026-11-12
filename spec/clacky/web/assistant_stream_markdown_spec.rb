# frozen_string_literal: true

require "open3"

RSpec.describe "Assistant streaming preview" do
  it "renders incremental deltas as markdown instead of raw text" do
    script = File.expand_path("../../support/assistant_stream_markdown_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
