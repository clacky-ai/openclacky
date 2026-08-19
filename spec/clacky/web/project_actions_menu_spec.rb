# frozen_string_literal: true

RSpec.describe "Project actions menu UI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:projects) { File.read(File.join(web_dir, "projects.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }

  it "embeds Lucide Pencil, Brush, and Trash icons for the three actions" do
    expect(projects).to include(
      'addItem(isPinned ? "projects.menu.unpin" : "projects.menu.pin",'
    )
    expect(projects).to include(
      'isPinned ? "Unpin" : "Pin to top", iconPin, false, pinToggle);'
    )
    expect(projects).to include(
      'addItem("projects.menu.edit", "Edit Project", iconEdit, false'
    )
    expect(projects).to include(
      'addItem("projects.menu.deleteSessions", "Delete Sessions", iconClearSessions, false'
    )
    expect(projects).to include(
      'addItem("projects.menu.delete", "Delete", iconTrash, true'
    )
    expect(projects).to include('viewBox="0 0 24 24" width="14" height="14"')
    expect(projects).to include('stroke="currentColor" stroke-width="2"')
    expect(projects).to include(
      'M12 20h9'
    )
    expect(projects).to include('M3 6h18')
    expect(projects).to include('const iconEdit = `<svg')
    expect(projects).to include('const iconPin = `<svg')
    expect(projects).to include('const iconClearSessions = `<svg')
    expect(projects).to include('const iconTrash = `<svg')
  end

  it "sorts pinned projects first and renders a pin badge" do
    expect(projects).to include("const pa = a.pinned_at || \"\"")
    expect(projects).to include("if (pa !== pb) return pb.localeCompare(pa)")
    expect(projects).to include("if (project.pinned_at)")
    expect(projects).to include('pin.className = "project-pin-badge"')
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
