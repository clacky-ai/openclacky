# frozen_string_literal: true

require "open3"

RSpec.describe "Web model modal vision autodetect" do
  it "pre-fills the no-vision box for custom endpoints from known model names" do
    script = File.expand_path("../../support/model_vision_autodetect_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
