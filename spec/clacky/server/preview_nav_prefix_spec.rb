# frozen_string_literal: true

require "open3"
require "tmpdir"
require "clacky/server/preview"

RSpec.describe "Preview navigation reporter" do
  it "keeps the preview prefix when a SPA pushes a root-absolute path" do
    report = Clacky::Server::Preview::PREVIEW_NAV_REPORT
    script = report[%r{<script>(.*)</script>}m, 1]
    expect(script).to be_a(String)
    expect(script).to include("keepPrefix")

    Dir.mktmpdir("clacky-preview-nav") do |dir|
      path = File.join(dir, "preview-nav-report.js")
      File.write(path, script)

      harness = File.expand_path("../../support/preview_nav_prefix_test.js", __dir__)
      output, status = Open3.capture2e("node", harness, path)
      expect(status.success?).to be(true), output
    end
  end
end
