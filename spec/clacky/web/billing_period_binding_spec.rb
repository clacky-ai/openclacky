# frozen_string_literal: true

# The recycle bin tabs and the task list filters reuse `.segmented-control__btn`,
# so a page-wide query bound billing's period handler to them as well: tapping a
# trash tab called `Billing.setPeriod(undefined)` and the billing page afterwards
# showed no highlighted period at all. Only billing's own buttons may be wired.
RSpec.describe "Billing period control binding" do
  let(:view) { File.read(File.expand_path("../../../lib/clacky/web/features/billing/view.js", __dir__)) }

  it "scopes the period buttons to the billing container" do
    expect(view).to include('container.querySelectorAll(".segmented-control__btn")')
    expect(view).not_to match(/document\.querySelectorAll\("\.segmented-control__btn"\)/)
  end

  it "reads the period from the button it bound, not from the click target" do
    expect(view).to include("Billing.setPeriod(btn.dataset.period)")
  end
end
