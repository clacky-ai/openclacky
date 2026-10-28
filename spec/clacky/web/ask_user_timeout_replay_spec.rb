# frozen_string_literal: true

require "open3"

RSpec.describe "Web ask_user card history replay" do
  it "keeps cards the agent resolved on its own closed after reload" do
    script = File.expand_path("../../support/ask_user_timeout_replay_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
