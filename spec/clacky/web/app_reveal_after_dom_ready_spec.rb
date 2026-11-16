# frozen_string_literal: true

require "open3"

RSpec.describe "Web first-paint reveal waits for DOMContentLoaded" do
  let(:script) { File.expand_path("../../support/app_reveal_after_dom_ready_test.js", __dir__) }

  it "reveals #app only after DOM-ready init has restored the layout, and only once" do
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
