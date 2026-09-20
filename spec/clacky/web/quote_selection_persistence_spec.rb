# frozen_string_literal: true

RSpec.describe "Quote selection persistence during live session updates" do
  let(:quote_select_js) do
    File.read(File.expand_path("../../../lib/clacky/web/components/quote-select.js", __dir__))
  end

  let(:sessions_js) do
    File.read(File.expand_path("../../../lib/clacky/web/sessions.js", __dir__))
  end

  it "keeps a captured quote while the running session mutates the message list" do
    init_body = quote_select_js[/function init\(\).*?^  \}/m]

    expect(init_body).not_to include("MutationObserver")
    expect(init_body).to include('document.addEventListener("scroll", _onScroll, true)')
    expect(quote_select_js).to include("range: range.cloneRange()")
    expect(quote_select_js).to include("_syncAnchor()")
    expect(quote_select_js).to include(
      "init, dismiss, hasActiveSelection, stage, list, restore, clear, count, toReferences, icon"
    )
  end

  it "does not auto-scroll live tool output while a quote action is available" do
    scroll_helper = sessions_js[/function _scrollToBottomIfNeeded\(container\).*?^  \}/m]

    expect(scroll_helper).to include("QuoteSelect.hasActiveSelection()")
    expect(scroll_helper).to include("_showNewMessageBanner()")
    expect(scroll_helper.index("QuoteSelect.hasActiveSelection()")).to be < scroll_helper.index("container.scrollTop")
  end

  it "dismisses the floating quote when its conversation is replaced" do
    expect(sessions_js).to match(
      /function _restoreMessages\(id\).*?QuoteSelect\.dismiss\(\).*?RenderTarget\.outer\(\)\.innerHTML = "";/m
    )
    expect(sessions_js).to match(
      /if \(options\.replace\).*?QuoteSelect\.dismiss\(\).*?RenderTarget\.outer\(\)\.replaceChildren\(\);/m
    )
    expect(sessions_js).to match(
      /_cacheActiveAndDeselect\(\).*?QuoteSelect\.dismiss\(\)/m
    )
  end
end
