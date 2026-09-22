# frozen_string_literal: true

require "open3"

RSpec.describe "Web queued guidance toggle" do
  let(:dispatcher) { File.expand_path("../../../lib/clacky/web/ws-dispatcher.js", __dir__) }

  it "lets an accepted guidance message be returned to the queue" do
    script = File.expand_path("../../support/input_queue_steer_toggle_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end

  it "never disables the toggle merely because the entry is already steering" do
    source = File.read(dispatcher)
    expect(source).to include("unsteer_pending_input")
    expect(source).not_to match(/guide\.disabled\s*=.*entry\.delivery === "steer"/)
  end

  it "offers both directions through i18n instead of hardcoded text" do
    i18n = File.read(File.expand_path("../../../lib/clacky/web/i18n.js", __dir__))
    %w[chat.input.cancelSteerMode chat.input.cancelSteerDescription].each do |key|
      expect(i18n.scan(/"#{Regexp.escape(key)}":/).size).to eq(2), "#{key} must exist in both locales"
    end
  end
end
