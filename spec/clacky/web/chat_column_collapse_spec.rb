# frozen_string_literal: true

require "open3"

RSpec.describe "Web chat column collapse" do
  it "hides the chat column once the aside crosses its minimum width" do
    script = File.expand_path("../../support/chat_column_collapse_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
