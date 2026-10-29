# frozen_string_literal: true

require "open3"

RSpec.describe "Web composer input history" do
  it "recalls sent messages with ArrowUp/ArrowDown" do
    script = File.expand_path("../../support/composer_input_history_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
