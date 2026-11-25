# frozen_string_literal: true

# The new-session model popover and the session info-bar dropdown render the
# same component, so they must also wear the same skin and offer the same
# reasoning card. These specs pin the wiring that keeps them from drifting
# apart again (each used to own a separate CSS container and a shorter list of
# populate() options).
RSpec.describe "Web model picker parity" do
  let(:root) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)  { File.read(File.join(root, "features/new-session/view.js")) }
  let(:store) { File.read(File.join(root, "features/new-session/store.js")) }
  let(:css)   { File.read(File.join(root, "app.css")) }

  it "dresses the new-session popover with the dropdown skin" do
    expect(view).to include('"ns-ctx-popover--model"')
    expect(css).to match(/\.sib-model-dropdown,\s*\.ns-ctx-popover--model \{/)
  end

  it "hands the reasoning slot to the picker with stops from the selected row" do
    expect(view).to match(/reasoning: _newReasoningOpts\(models, currentId\)/)
    expect(view).to match(/levels: \(row && row\.reasoning_levels\) \|\| \[\]/)
  end

  it "remembers the chosen stop on the draft" do
    expect(store).to include("reasoningEffort:")
    expect(store).to include("payload.reasoning_effort = adv.reasoningEffort")
  end

  it "snaps the draft stop onto the new model's stops when the model changes" do
    expect(view).to match(/levels\[ModelPicker\.reasoningIndex\(levels, eff\)\]/)
    expect(File.read(File.join(root, "components/model-picker.js"))).to match(/^\s{4}reasoningIndex,$/)
  end
end
