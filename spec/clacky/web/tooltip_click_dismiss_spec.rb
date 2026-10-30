# frozen_string_literal: true

require "open3"

RSpec.describe "Web shared tooltip" do
  it "hides on click and stays hidden until the pointer leaves the anchor" do
    script = File.expand_path("../../support/tooltip_click_dismiss_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
