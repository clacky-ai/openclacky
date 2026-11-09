# frozen_string_literal: true

require "open3"

RSpec.describe "Web desktop notification title" do
  let(:root) { File.expand_path("../../..", __dir__) }
  let(:i18n) { File.read(File.join(root, "lib/clacky/web/i18n.js")) }

  it "names the finished session in the title" do
    script = File.expand_path("../../support/notify_session_title_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end

  it "keeps both title variants in both locales" do
    %w[
      notify.desktop.title
      notify.desktop.titleWithName
      notify.desktop.awaiting.title
      notify.desktop.awaiting.titleWithName
    ].each do |key|
      expect(i18n.scan(%("#{key}":)).length).to eq(2), "#{key} is missing from a locale"
    end
  end

  it "interpolates the name rather than appending it in code" do
    expect(i18n).to include('"notify.desktop.titleWithName": "任务完成 · {{name}}"')
    expect(i18n).to include('"notify.desktop.titleWithName": "Task complete · {{name}}"')
  end
end
