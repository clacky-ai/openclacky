# frozen_string_literal: true

require "open3"

RSpec.describe "Web model modal: OpenClacky AI Keys promo visibility" do
  let(:script) { File.expand_path("../../support/provider_promo_visibility_test.js", __dir__) }

  it "shows the promo only while no provider is picked, or for OpenClacky itself" do
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end
end
