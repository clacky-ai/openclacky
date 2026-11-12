# frozen_string_literal: true

require "open3"

RSpec.describe "Sidebar settings tip" do
  it "stays dismissed once the user closes or opens Settings" do
    script = File.expand_path("../../support/sidebar_settings_tip_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
