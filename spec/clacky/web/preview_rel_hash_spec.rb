# frozen_string_literal: true

require "open3"

RSpec.describe "Preview address bar keeps the URL fragment (C-5858)" do
  let(:script) { File.expand_path("../../support/preview_rel_hash_test.js", __dir__) }

  it "parses and builds preview URLs with their #fragment" do
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
