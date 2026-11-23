# frozen_string_literal: true

require "open3"

RSpec.describe "Web aside tab strip" do
  it "opens nothing by default, groups tools vs extensions, and remembers per session" do
    script = File.expand_path("../../support/aside_tabs_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
