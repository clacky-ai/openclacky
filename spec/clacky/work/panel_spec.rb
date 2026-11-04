# frozen_string_literal: true
require "spec_helper"
require "open3"

RSpec.describe "Secretary work panel" do
  it "uses extension slots and events, and returns edits to the conversation" do
    output, status = Open3.capture2e("node", "spec/support/secretary_work_panel_test.js")
    expect(status.success?).to be(true), output
  end
end
