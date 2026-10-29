# frozen_string_literal: true

# Naming a new branch happens in a modal (the popover is too narrow to show the
# prefix rule and git's validation messages), so the popover footer must only
# open that modal instead of growing an inline text field.
RSpec.describe "New-session create-branch modal" do
  let(:root) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view) { File.read(File.join(root, "features/new-session/view.js")) }
  let(:styles) { File.read(File.join(root, "app.css")) }

  it "opens the modal from the popover footer instead of an inline field" do
    expect(view).to include("function _openCreateBranchModal()")
    expect(view).to include("_dismissCtxPopover();\n        _openCreateBranchModal();")
    expect(view).not_to include("ns-branch-create-input")
  end

  it "reuses the shared modal shell and IME-safe Enter handling" do
    expect(view).to include('overlay.className = "modal-overlay"')
    expect(view).to include("modal-box sm ns-branch-modal")
    expect(view).to include("IME.bindEnter(input, submit)")
    expect(view).to include('if (e.key === "Escape") { e.preventDefault(); close(); }')
  end

  it "validates names locally before calling git" do
    %w[/ // .. .lock].each do |token|
      expect(view).to include(token)
    end
    expect(view).to include("_branchNameError(fullName(), zh)")
    expect(view).to include("already exists")
  end

  it "styles the prefix chip and the invalid state" do
    expect(styles).to include(".ns-branch-prefix-chip {")
    expect(styles).to include(".ns-branch-name-row:focus-within {")
    expect(styles).to include(".ns-branch-name-row.is-invalid {")
    expect(styles).not_to include(".ns-branch-create-input {")
  end
end
