# frozen_string_literal: true

# Pointing a session at another working directory has to reset the Files panel:
# the rows, the search results and the open tabs all came from the old root, so
# leaving them on screen shows (and copies) paths that no longer exist.
RSpec.describe "Files panel reset on working dir switch" do
  let(:view) do
    File.read(File.expand_path("../../../lib/clacky/web/features/workspace/view.js", __dir__))
  end
  let(:store) do
    File.read(File.expand_path("../../../lib/clacky/web/features/workspace/store.js", __dir__))
  end

  it "tells listeners which session the change replaced" do
    emit = store[/if \(changed\) _emit\("workspace:sessionChanged".*?\);/m]
    expect(emit).to include("sessionId: newId")
    expect(emit).to include("prevSessionId: prevId")
  end

  it "drops the search when the working dir changes" do
    handler = view[/const offSessionChanged = Workspace\.on\("workspace:sessionChanged".*?\n    \}\);/m]
    expect(handler).to include('searchInput.value = ""')
    expect(handler).to include("clearTimeout(searchTimer)")
    expect(handler).to include("showTree()")
    expect(handler).to include("treeState.activePath = null")
    expect(handler).to include("reloadTree({ reset: true })")
  end

  it "closes the open tabs and forgets the record only for the same session" do
    handler = view[/const offSessionChanged = Workspace\.on\("workspace:sessionChanged".*?\n    \}\);/m]
    expect(handler).to include("payload.prevSessionId === payload.sessionId")
    expect(handler).to include("forgetOpenTabs(payload.sessionId)")
    expect(handler).to include("viewer.reset()")
  end

  it "resets the viewer without asking about unsaved edits" do
    reset = view[/function reset\(\) \{.*?\n    \}/m]
    expect(reset).to include("tabs.splice(0).forEach(disposeTab)")
    expect(reset).to include("activate(null)")
    expect(reset).to include("skipPersist = true")
    expect(reset).to include("skipPersist = false")
    expect(reset).not_to include("Modal.confirm")

    expect(view).to include("return { root, openTab, activate, reloadOpenTabs, reset, destroy };")
  end

  it "keeps another session's open-tab record while the strip is being cleared" do
    persist = view[/function persistTabs\(\) \{.*?\n    \}/m]
    expect(persist).to include("if (skipPersist) return;")

    forget = view[/function forgetOpenTabs\(sessionId\) \{.*?\n  \}/m]
    expect(forget).to include("delete data[sessionId]")
    expect(forget).to include("writeOpenTabs(data)")
  end
end
