# frozen_string_literal: true

require "open3"

RSpec.describe "Web external deep link (#new?prompt=…)" do
  let(:script) { File.expand_path("../../support/deep_link_test.js", __dir__) }
  let(:i18n)   { File.read(File.expand_path("../../../lib/clacky/web/i18n.js", __dir__)) }
  let(:html)   { File.read(File.expand_path("../../../lib/clacky/web/index.html", __dir__)) }

  it "parses the link, drops over-long prompts, and never sends on its own" do
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end

  it "ships the notice copy in both languages" do
    %w[fromLink long tooLong].each do |key|
      occurrences = i18n.scan(%("newSession.deepLink.#{key}")).size
      expect(occurrences).to eq(2), "expected an en and a zh string for newSession.deepLink.#{key}"
    end
  end

  it "has the notice element the view writes into" do
    expect(html).to include('id="ns-deeplink-notice"')
  end
end
