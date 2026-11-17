# frozen_string_literal: true

require "open3"

RSpec.describe "Git panel empty file note" do
  it "labels created and deleted empty files instead of reporting no change" do
    script = File.expand_path("../../support/git_panel_empty_file_note_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
