# frozen_string_literal: true

require "open3"

RSpec.describe "Web attachment image previews" do
  it "only renders thumbnails for formats /api/local-image serves" do
    script = File.expand_path("../../support/attachment_image_preview_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
