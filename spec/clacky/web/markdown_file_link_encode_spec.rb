# frozen_string_literal: true

require "open3"

RSpec.describe "Markdown file link encoding" do
  it "keeps file:// links with spaces or parentheses intact for marked" do
    script = File.expand_path("../../support/markdown_file_link_encode_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
