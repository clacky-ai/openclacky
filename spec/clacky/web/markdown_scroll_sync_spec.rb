# frozen_string_literal: true

require "open3"

RSpec.describe "Web markdown split view scroll sync" do
  it "keeps the editor and the preview on the same relative position" do
    script = File.expand_path("../../support/markdown_scroll_sync_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end

  it "wires the sync into the workspace viewer and the markdown editor modal" do
    root = File.expand_path("../../..", __dir__)
    viewer = File.read(File.join(root, "lib/clacky/web/features/workspace/view.js"))
    editor = File.read(File.join(root, "lib/clacky/web/components/code-editor.js"))

    expect(viewer).to include("CodeEditor.linkScrollSync(tab.editor.view.scrollDOM, tab.previewEl)")
    expect(viewer).to include("tab.scrollSync.syncFrom(tab.editor.view.scrollDOM)")
    expect(viewer.scan("CodeEditor.renderMarkdown(tab.editor.getContent())").length).to eq(1)

    expect(editor).to include("_linkScrollSync(view.scrollDOM, previewPane)")
    expect(editor).to include("linkScrollSync: _linkScrollSync")
  end

  it "keeps the preview scroll position when the markdown is re-rendered" do
    root = File.expand_path("../../..", __dir__)
    viewer = File.read(File.join(root, "lib/clacky/web/features/workspace/view.js"))
    editor = File.read(File.join(root, "lib/clacky/web/components/code-editor.js"))

    expect(viewer).to match(/const top = tab\.previewEl\.scrollTop;.*tab\.previewEl\.scrollTop = top;/m)
    expect(editor).to match(/const top = previewPane\.scrollTop;.*previewPane\.scrollTop = top;/m)
  end
end
