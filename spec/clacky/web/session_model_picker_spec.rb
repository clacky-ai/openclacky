# frozen_string_literal: true

require "open3"

RSpec.describe "Session model picker interactions" do
  script = File.expand_path("../../support/session_model_picker_test.js", __dir__)

  {
    "close-race" => "does not reopen after it is closed while models are loading",
    "session-race" => "does not render a response for a session that is no longer active",
    "disabled-anchor-race" => "does not open after the same session starts running while models load",
    "restored-runtime" => "uses the session-owned runtime descriptor when its global card is gone",
    "http-error" => "rejects unsuccessful config responses with localized feedback",
  }.each do |scenario, description|
    it description do
      output, status = Open3.capture2e("node", script, scenario)
      expect(status.success?).to be(true), output
    end
  end
end
