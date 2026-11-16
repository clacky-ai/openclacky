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

  # A spent stream budget turns later files into load-on-click placeholders; it
  # never truncates the file being drawn. Reporting the leftover budget as the
  # visible row count told users "showing the first 2984 lines" while the body
  # held all 3995 of them.
  it "reports the rows actually rendered, not the leftover budget" do
    expect(body).not_to include("rendered >= limit")
    expect(body).to include('replace("{{n}}", String(rendered))')
  end

  it "shows the note only when the payload or the body was really clipped" do
    expect(body).to include("if (file.truncated || clipped)")
    expect(body).to include("let clipped = false;")
  end

  it "marks a clip only on a MAX_RENDER_LINES early exit" do
    expect(body).to include("if (rendered >= MAX_RENDER_LINES) { clipped = true; break; }")
    expect(body).to include("clipped = clipped || h + 1 < hunks.length;")
  end
end
