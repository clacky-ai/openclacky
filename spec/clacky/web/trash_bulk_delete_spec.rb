# frozen_string_literal: true

require "open3"

RSpec.describe "Recycle bin bulk delete" do
  it "only clears the sessions the filters leave visible" do
    script = File.expand_path("../../support/trash_bulk_delete_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
