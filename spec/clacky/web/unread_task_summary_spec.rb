# frozen_string_literal: true

require "open3"

RSpec.describe "Web unread task summary" do
  it "keeps the done summary until the finished session is first opened" do
    script = File.expand_path("../../support/unread_task_summary_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
