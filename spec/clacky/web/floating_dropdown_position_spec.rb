# frozen_string_literal: true

require "open3"

RSpec.describe "Floating dropdown positioning" do
  it "keeps portalled dropdowns inside the viewport" do
    script = File.expand_path("../../support/floating_dropdown_position_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
