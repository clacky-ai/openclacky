# frozen_string_literal: true

require "open3"

RSpec.describe "Markdown project file refs" do
  it "restores hosted-platform references to file:// links at render time" do
    script = File.expand_path("../../support/markdown_project_file_ref_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
