# frozen_string_literal: true

require "open3"

RSpec.describe "New-session runtime guards" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:new_session_view) do
    File.read(File.join(web_dir, "features/new-session/view.js"))
  end

  it "passes model-refresh and UI-inserted skill command regressions" do
    script = File.expand_path("../../support/new_session_runtime_guards_test.js", __dir__)
    output, status = Open3.capture2e("node", script)

    expect(status.success?).to be(true), output
  end

  it "strips UI-inserted skill commands both when selecting and submitting a runtime" do
    runtime_select = new_session_view[/onSelect:\s*\(m\)\s*=>\s*\{.*?\n\s*\},/m]
    submit = new_session_view[/async function _submit\(\).*?(?=\n\s*function _bindOnce)/m]

    expect(runtime_select).to include("_stripInsertedSkillCommand")
    expect(submit).to include("_stripInsertedSkillCommand")
  end
end
