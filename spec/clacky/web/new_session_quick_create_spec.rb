# frozen_string_literal: true

require "open3"

RSpec.describe "Web sidebar quick new session" do
  it "ignores the unsubmitted /#new draft and leaves it intact" do
    script = File.expand_path("../../support/new_session_quick_create_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
