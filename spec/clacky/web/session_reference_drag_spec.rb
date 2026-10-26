# frozen_string_literal: true

require "open3"

RSpec.describe "Web session reference drag and drop" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:sessions) { File.read(File.join(web_dir, "sessions.js")) }
  let(:projects) { File.read(File.join(web_dir, "projects.js")) }
  let(:new_session) { File.read(File.join(web_dir, "features/new-session/view.js")) }
  let(:i18n) { File.read(File.join(web_dir, "i18n.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }

  it "round-trips and validates the shared Composer drag payload" do
    script = File.expand_path("../../support/session_reference_drag_test.js", __dir__)
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end

  it "makes rendered sessions draggable without duplicating reference serialization" do
    expect(sessions).to include("el.draggable = true")
    expect(sessions).to include("Composer.beginReferenceDrag(e.dataTransfer")
    expect(sessions).to include('type: "session"')
  end

  it "binds the chat column and the new-session page as shared drop zones" do
    expect(sessions).to include('zone: document.getElementById("chat-main")')
    expect(sessions).not_to include('zone: document.getElementById("chat-panel")')
    expect(new_session).to include('zone: $("welcome")')
    expect(sessions).not_to include('inputArea.addEventListener("drop"')
    expect(new_session).not_to include('composer.addEventListener("drop"')
  end

  it "provides a compact drag preview and page-level drop-target feedback" do
    expect(styles).to include(".reference-drag-preview")
    expect(styles).to include(".session-item.is-dragging")
    expect(styles).to include("#chat-main.drag-over")
    expect(styles).not_to include("#chat-panel.drag-over")
    expect(styles).to include("#welcome.drag-over")
  end

  it "uses the same session drag as a copy in composers and a move in the sidebar" do
    expect(projects).to include('event.dataTransfer.dropEffect = "move"')
    expect(projects).to include('await moveSession(dragged.id, target.projectId)')
    expect(projects).to include('target.projectId === _draggedSession.projectId')
    expect(projects).to include('node.closest("#chat-section")')
    expect(projects).to include('node.closest("[data-project-drop-id]")')
    expect(projects).to include('Composer.acceptsSessionDrag(event.dataTransfer)')
    expect(projects).to include('chip.sessionId !== dragged.id')
    expect(projects).to include('group.className = "project-group"')
    expect(projects).to include('group.dataset.projectDropId = project.id')
    expect(projects).not_to include('header.dataset.projectDropId = project.id')
    expect(projects).not_to include('sessionGroup.dataset.projectDropId = project.id')
    expect(sessions).to include('el.dataset.projectId = s.project_id')
  end

  it "clears drag feedback and reports a failed move" do
    expect(projects).to include('document.addEventListener("dragend"')
    expect(projects).to include('_clearDropTarget()')
    expect(styles).to include(".session-move-drop-target")
    expect(i18n).to include('"sessions.moveToProject.failed"')
  end
end
