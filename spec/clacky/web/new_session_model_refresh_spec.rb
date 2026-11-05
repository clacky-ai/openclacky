# frozen_string_literal: true

RSpec.describe "Web new-session model list refresh" do
  let(:view) do
    File.read(File.expand_path("../../../lib/clacky/web/features/new-session/view.js", __dir__))
  end

  it "re-fetches the model list every time the panel is shown" do
    expect(view).to match(/async function onPanelShow[\s\S]*?await _populateModels\(\)/)
  end

  it "does not cache the list behind a one-shot flag" do
    expect(view).not_to include("_modelsLoaded")
    expect(view).to match(
      /_modelsPromise = NewSessionStore\.loadModels\(\)[\s\S]*?\.finally\(\(\) => \{ _modelsPromise = null; \}\)/
    )
  end

  it "falls back to the default model when the remembered id is gone" do
    expect(view).to include(
      'const known = models.some((m) => (m.id || "") === adv.modelId);'
    )
    expect(view).to match(
      /if \(models\.length && !known\) \{\s*const def = models\.find\(\(m\) => m\.type === "default"\) \|\| models\[0\];/
    )
  end
end
