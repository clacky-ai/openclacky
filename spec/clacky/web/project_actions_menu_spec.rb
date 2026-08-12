# frozen_string_literal: true

RSpec.describe "Project actions menu UI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:projects) { File.read(File.join(web_dir, "projects.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }

  it "embeds Lucide Pencil and Trash2 icons for the three actions" do
    expect(projects).to include(
      'addItem("projects.menu.edit", "Edit Project", iconEdit, false'
    )
    expect(projects).to include(
      'addItem("projects.menu.deleteSessions", "Delete Sessions", iconTrash, false'
    )
    expect(projects).to include(
      'addItem("projects.menu.delete", "Delete", iconTrash, true'
    )
    expect(projects).to include('viewBox="0 0 24 24" width="14" height="14"')
    expect(projects).to include('stroke="currentColor" stroke-width="2"')
    expect(projects).to include(
      'M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174'
    )
    expect(projects).to include('<path d="M10 11v6"/><path d="M14 11v6"/>')
    expect(projects).to include('const iconEdit = `<svg')
    expect(projects).to include('const iconTrash = `<svg')
  end

  it "matches the existing 14px menu icon size and themes only deletion as dangerous" do
    expect(styles).to match(
      /\.project-actions-menu-icon \{.*?width: 0\.875rem;.*?height: 0\.875rem;/m
    )
    expect(styles).not_to include("project-edit.svg")
    expect(styles).not_to include("project-trash.svg")
    expect(styles).to include(".project-actions-menu-icon svg")
    expect(styles).to match(
      /\.project-actions-menu-item\.danger .*?color: var\(--color-error\);/m
    )
  end
end
