# frozen_string_literal: true

require "open3"

RSpec.describe "Web composer draft persistence" do
  it "keeps per-session drafts across a reload via IndexedDB" do
    script = File.expand_path("../../support/composer_draft_persist_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
