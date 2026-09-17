# frozen_string_literal: true

require "open3"

RSpec.describe "Web workspace binary handoff" do
  it "hands safe linked binaries to the OS without changing Files viewer behavior" do
    script = File.expand_path("../../support/workspace_binary_handoff_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end

  it "waits for the linked-file handler before falling back to file-action" do
    source = File.read(File.expand_path("../../../lib/clacky/web/sessions.js", __dir__))
    expect(source).to match(/await Clacky\.WorkspaceView\.openLinkedFile\(filePath\)/)
    expect(source).not_to include("Clacky.WorkspaceView.openFile(filePath)")
  end
end
