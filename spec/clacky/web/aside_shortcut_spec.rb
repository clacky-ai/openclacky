# frozen_string_literal: true

require "open3"

RSpec.describe "Web aside collapse shortcut" do
  it "toggles the aside column with the advertised keyboard shortcut" do
    script = File.expand_path("../../support/aside_shortcut_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
