# frozen_string_literal: true

RSpec.describe "Version upgrade popover · changelog link" do
  let(:view) { File.read(File.expand_path("../../../lib/clacky/web/features/version/view.js", __dir__)) }
  let(:confirm_state) { view[/function _renderConfirmState\(pop, s\) \{\n(.*?)^  \}/m, 1] }

  it "renders the changelog link when an update is available" do
    expect(confirm_state).to include("vup-btn-changelog")
    expect(confirm_state).to include("github.com/clacky-ai/openclacky/releases")
  end

  it "renders it for branded builds too" do
    expect(confirm_state).not_to include("Brand")
    expect(view).not_to include("Brand")
  end
end
