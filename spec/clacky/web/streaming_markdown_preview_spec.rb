# frozen_string_literal: true

require "open3"

RSpec.describe "Web streaming markdown preview" do
  it "keeps already-shown words on screen while a reply is still arriving" do
    script = File.expand_path("../../support/streaming_markdown_preview_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
