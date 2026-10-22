# frozen_string_literal: true

require "open3"

RSpec.describe "Data management live refresh" do
  it "refreshes the open archive or recycle bin page after a sidebar archive or delete" do
    script = File.expand_path("../../support/data_management_live_refresh_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
