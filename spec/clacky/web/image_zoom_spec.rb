# frozen_string_literal: true

require "open3"

RSpec.describe "Web image zoom controller" do
  it "shares fitted zoom, bounded pan and cleanup across image viewers" do
    script = File.expand_path("../../support/image_zoom_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
