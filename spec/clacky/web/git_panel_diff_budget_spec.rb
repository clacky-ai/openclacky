# frozen_string_literal: true

# The diff stream shares one render budget, and it is spent as files are drawn.
# A layout switch re-renders every visible body, but by then the budget is
# already gone, so a record that once rendered has to be remembered: otherwise
# every file on screen falls back to the load-on-click placeholder and the user
# has to click each one again.
RSpec.describe "Git panel diff render budget" do
  let(:view) do
    File.read(File.expand_path("../../../lib/clacky/default_extensions/git/panels/git/view.js", __dir__))
  end

  let(:body) { view[/function renderFileBody\(section, file\) \{.*?\n  \}/m] }

  it "lets an already rendered body skip the spent budget" do
    expect(body).to include("const limit = (full || record.loaded || record.shown) ? MAX_RENDER_LINES")
  end

  it "remembers the file once its body has lines" do
    expect(body).to include("if (rendered > 0) record.shown = true;")
  end

  it "still charges the budget on the first render only" do
    # Without the reflow guard every layout switch would charge the budget
    # again for lines it already paid for.
    expect(body).to include("if (!full && !record.loaded && !state.reflow) state.budget -= rendered;")
  end

  it "keeps the record map across a reflow" do
    reflow = view[/function reflowBodies\(\) \{.*?\n  \}/m]
    expect(reflow).not_to include("state.records = new Map()")
    expect(reflow).to include("renderFileBody(section, file)")
  end
end
