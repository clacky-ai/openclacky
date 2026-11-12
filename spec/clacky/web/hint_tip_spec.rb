# frozen_string_literal: true

require "open3"

RSpec.describe "HintTip" do
  it "shows once, anchors correctly and stays dismissed" do
    script = File.expand_path("../../support/hint_tip_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
