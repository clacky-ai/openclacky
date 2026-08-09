# frozen_string_literal: true

require "clacky/ui2/ui_controller"
require "clacky/ui2/progress_handle"
require "clacky/ui2/view_renderer"

# Chore phases (memory update, skill evolution) are background work the user
# never asked for. The web UI folds them into a collapsible card; a
# line-oriented terminal has no folding, so the CLI instead:
#
#   * collapses the whole phase to ONE live line while it runs, folding the
#     subagent's nested progress into it, and
#   * prints a short digest afterwards — the collapsed-card equivalent.
#
# The bug this guards against: nested handles used to register their own
# buffer entries, and each committed a permanent final frame on finish, so a
# single memory update left ~15 "Ruminating… (23s)" tombstones on screen.
RSpec.describe Clacky::UI2::UIController, "chore phase output" do
  class ChoreFakeLayout
    def initialize
      @entries = {}
      @order = []
      @next_id = 0
    end

    def append_output(content)
      @next_id += 1
      @entries[@next_id] = content
      @order << @next_id
      @next_id
    end

    def update_entry(id, content)
      @entries[id] = content if @entries.key?(id)
    end

    def remove_entry(id)
      @entries.delete(id)
      @order.delete(id)
    end

    def render_input; end
    def hide_todos; end

    def visible
      @order.map { |id| @entries[id] }.compact
    end

    def text
      visible.join("\n")
    end
  end

  def build_controller
    layout = ChoreFakeLayout.new
    ctrl = Clacky::UI2::UIController.allocate
    ctrl.instance_variable_set(:@layout, layout)
    ctrl.instance_variable_set(:@renderer, Clacky::UI2::ViewRenderer.new)
    ctrl.instance_variable_set(:@progress_mutex, Mutex.new)
    ctrl.instance_variable_set(:@progress_stack, [])
    ctrl.instance_variable_set(:@config, Struct.new(:verbose).new(false))
    ctrl.instance_variable_set(:@stdout_lines, [])
    ctrl.define_singleton_method(:update_sessionbar) { |**| }
    ctrl.define_singleton_method(:update_entry) { |id, c| @layout.update_entry(id, c) }
    ctrl.define_singleton_method(:remove_entry) { |id| @layout.remove_entry(id) }
    [ctrl, layout]
  end

  after { Thread.current[:clacky_chore_phase] = nil }

  describe "while the chore runs" do
    it "collapses nested progress and transcript into a single line" do
      ctrl, layout = build_controller
      pid = ctrl.phase_start(kind: "memory_update", label: "Updating long-term memory")

      15.times do |i|
        handle = ctrl.start_progress(message: "Ruminating#{i}", style: :primary)
        ctrl.show_tool_call("read", { "path" => "notes.md" })
        ctrl.show_assistant_message("chatter", files: nil)
        handle.finish
      end

      expect(layout.visible.size).to eq(1)
      ctrl.phase_end(pid, summary: "done")
    end

    it "surfaces the innermost activity on the chore line" do
      ctrl, layout = build_controller
      pid = ctrl.phase_start(kind: "memory_update", label: "Updating long-term memory")
      handle = ctrl.start_progress(message: "Executing invoke_skill", style: :primary)

      line = layout.visible.first
      expect(line).to include("Updating long-term memory")
      expect(line).to include("Executing invoke_skill")

      handle.finish
      expect(layout.visible.first).not_to include("Executing invoke_skill")
      ctrl.phase_end(pid, summary: nil)
    end
  end

  describe "the digest printed afterwards" do
    it "reports the tool calls that ran" do
      ctrl, layout = build_controller
      pid = ctrl.phase_start(kind: "memory_update", label: "Updating long-term memory")
      3.times { ctrl.show_tool_call("read", {}) }
      ctrl.show_tool_call("edit", {})
      ctrl.phase_end(pid, summary: "2 memories updated")

      expect(layout.text).to include("4 tool calls")
      expect(layout.text).to include("read×3")
      expect(layout.text).to include("2 memories updated")
    end

    it "lists touched files and caps the list" do
      ctrl, layout = build_controller
      pid = ctrl.phase_start(kind: "memory_update", label: "L")
      30.times { |i| ctrl.show_file_edit_preview("memories/file#{i}.md") }
      ctrl.phase_end(pid, summary: "s")

      expect(layout.text).to include("memories/file0.md")
      expect(layout.text).to include("more file")
      expect(layout.visible.size).to be <= 1 + Clacky::UI2::UIController::CHORE_DIGEST_MAX_FILES + 2
    end

    it "flags tool kinds omitted from the digest" do
      ctrl, layout = build_controller
      pid = ctrl.phase_start(kind: "memory_update", label: "L")
      %w[read edit write grep glob bash].each { |t| ctrl.show_tool_call(t, {}) }
      ctrl.phase_end(pid, summary: "s")

      expect(layout.text).to include("6 tool calls")
      expect(layout.text).to match(/\+\d+ more/)
    end

    it "flags errors omitted from the digest instead of dropping them silently" do
      ctrl, layout = build_controller
      pid = ctrl.phase_start(kind: "memory_update", label: "L")
      6.times { |i| ctrl.show_tool_error("boom #{i}") }
      ctrl.phase_end(pid, summary: nil)

      expect(layout.text).to include("boom 0")
      expect(layout.text).to match(/…\d+ more errors/)
    end

    it "never swallows errors, even with no summary" do
      ctrl, layout = build_controller
      pid = ctrl.phase_start(kind: "memory_update", label: "L")
      ctrl.show_tool_error("write denied: read-only fs")
      ctrl.phase_end(pid, summary: nil)

      expect(layout.text).to include("write denied: read-only fs")
    end

    it "leaves no trace when the chore did nothing worth reporting" do
      ctrl, layout = build_controller
      pid = ctrl.phase_start(kind: "memory_update", label: "L")
      ctrl.start_progress(message: "Ruminating", style: :primary).finish
      ctrl.phase_end(pid, summary: nil)

      expect(layout.visible).to be_empty
    end

    it "starts fresh for each chore" do
      ctrl, layout = build_controller
      2.times do
        pid = ctrl.phase_start(kind: "memory_update", label: "L")
        ctrl.show_tool_call("read", {})
        ctrl.phase_end(pid, summary: "s")
      end

      expect(layout.visible.last(2).join("\n")).to include("1 tool call")
    end
  end

  describe "non-chore phases" do
    it "keep their full transcript" do
      ctrl, layout = build_controller
      pid = ctrl.phase_start(kind: "coding", label: "Coding")
      ctrl.show_tool_call("edit", { "path" => "app.rb" })
      ctrl.show_file_edit_preview("app.rb")
      ctrl.show_tool_error("oops")
      ctrl.phase_end(pid, summary: nil)

      expect(layout.text.downcase).to include("edit(app.rb)")
      expect(layout.text).to include("app.rb")
      expect(layout.text).to include("oops")
      expect(layout.text).to include("Coding")
    end
  end
end
