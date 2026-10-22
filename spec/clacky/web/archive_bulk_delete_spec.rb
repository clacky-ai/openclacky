# frozen_string_literal: true

require "open3"

RSpec.describe "Archive bulk delete" do
  it "only deletes the archived sessions the search and filters leave visible" do
    script = File.expand_path("../../support/archive_bulk_delete_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
