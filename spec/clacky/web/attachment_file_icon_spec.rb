# frozen_string_literal: true

require "open3"

RSpec.describe "Web attachment file icons" do
  it "draws attachment chips with the workspace file-tree icon" do
    script = File.expand_path("../../support/attachment_file_icon_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
