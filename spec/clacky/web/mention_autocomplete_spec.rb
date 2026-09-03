# frozen_string_literal: true

RSpec.describe "Web mention autocomplete" do
  let(:source) do
    File.read(File.expand_path("../../../lib/clacky/web/components/mentions.js", __dir__))
  end

  it "falls back to committed input when IME keydown is not usable" do
    expect(source).to include('function _adoptCommittedAtMarker()')
    expect(source).to include(
      'if (!_visible && !e.isComposing && e.data === "@" && _adoptCommittedAtMarker())'
    )
    expect(source).to include(
      'if (!_visible && e.data === "@" && _adoptCommittedAtMarker()) open("root")'
    )
  end

  it "waits for compositionend before rewriting active IME text" do
    input_handler = source[/el\.addEventListener\("input".*?^    \}\);/m]
    composition_handler = source[/el\.addEventListener\("compositionend".*?^    \}\);/m]

    expect(input_handler).to include("!e.isComposing")
    expect(composition_handler).to include('_adoptCommittedAtMarker()')
  end

  it "uses named DOM and caret positions when adopting committed text" do
    expect(source).to include("node.nodeType !== Node.TEXT_NODE")
    expect(source).to include("node.nodeType !== Node.ELEMENT_NODE")
    expect(source).to include("const previousChildIndex = offset - 1")
    expect(source).to include("const atOffset = offset - 1")
    expect(source).not_to match(/node\.nodeType !== [13]/)
  end
end
