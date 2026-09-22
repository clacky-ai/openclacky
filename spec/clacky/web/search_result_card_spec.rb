# frozen_string_literal: true

require "open3"

RSpec.describe "Web search result card" do
  it "promotes web_search results into a standalone message card" do
    script = File.expand_path("../../support/search_result_card_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
