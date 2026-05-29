# frozen_string_literal: true

require "clacky/ui2/ui_controller"
require "clacky/ui2/progress_handle"

# Regression test: when an active progress indicator currently sits at the
# tail of the OutputBuffer, calling +append_output+ for non-progress
# content must rotate the progress so it ends up at the new tail again.
#
# Why this matters:
#   * Visually, the spinner belongs at the bottom of the output area.
#     If business content is appended *under* the spinner, the user sees
#     the spinner above newly-arrived messages — the wrong reading order.
#   * Mechanically, the progress ticker repaints its entry every ~100ms.
#     LayoutManager#replace_entry repaints in place only when the entry
#     is the buffer tail; otherwise it falls back to a full output
#     repaint. Once the progress is no longer the tail, every tick wipes
#     and redraws the whole output area — visible flicker.
#
# Both problems disappear if the progress entry is rotated to remain at
# the tail after each non-progress append.
RSpec.describe Clacky::UI2::UIController, "#append_output progress rotation" do
  # Fake layout: just enough buffer-like behaviour for the rotation logic
  # to inspect and mutate. Records the high-level call sequence so the
  # spec can assert ordering.
  class RotationFakeLayout
    Entry = Struct.new(:id, :content)

    attr_reader :calls, :entries

    def initialize
      @entries = []
      @next_id = 1
      @calls = []
    end

    def append_output(content)
      id = @next_id
      @next_id += 1
      @entries << Entry.new(id, content)
      @calls << [:append, id, content]
      id
    end

    def remove_entry(id)
      @entries.reject! { |e| e.id == id }
      @calls << [:remove, id]
    end

    # The real LayoutManager exposes its OutputBuffer via #buffer; the
    # rotation logic only consults +buffer.live_entries.last.id+, so a
    # tiny shim is enough.
    def buffer
      self
    end

    def live_entries
      @entries
    end
  end

  def build_controller(layout)
    ctrl = Clacky::UI2::UIController.allocate
    ctrl.instance_variable_set(:@layout, layout)
    ctrl.instance_variable_set(:@progress_mutex, Mutex.new)
    ctrl.instance_variable_set(:@progress_stack, [])
    ctrl.instance_variable_set(:@stdout_lines, nil)
    ctrl.instance_variable_set(:@last_sessionbar_status, "idle")
    ctrl.instance_variable_set(:@renderer, FakeRenderer.new)
    ctrl
  end

  class FakeRenderer
    def render_progress(s); "P:#{s}"; end
    def render_working(s);  "W:#{s}"; end
  end

  # Stand-in for the parts of ProgressHandle that the rotation path
  # touches. Behaves like a top-of-stack handle with a mutable entry id.
  class FakeHandle
    attr_accessor :entry_id, :style

    def initialize(entry_id:, style: :primary, frame: "Analyzing")
      @entry_id = entry_id
      @style    = style
      @frame    = frame
    end

    def current_frame; @frame; end
    def __detach_entry!; @entry_id = nil; end
    def __rebind_entry!(new_id); @entry_id = new_id; end
  end

  it "rotates an active tail-of-buffer progress to remain at the tail" do
    layout = RotationFakeLayout.new
    ctrl   = build_controller(layout)

    # Pre-existing business line and the active progress (the progress
    # is currently the tail, mirroring the state right after
    # @ui&.show_progress was called early in agent.run).
    layout.append_output("hello world")
    progress_entry = layout.append_output("P:Analyzing… (0s)")
    handle = FakeHandle.new(entry_id: progress_entry)
    ctrl.instance_variable_get(:@progress_stack).push(handle)

    layout.calls.clear

    returned_id = ctrl.append_output("Injected skill content for /jade-appraisal")

    # Final on-screen order: hello world, injected message, spinner.
    expect(layout.entries.map(&:content)).to eq([
      "hello world",
      "Injected skill content for /jade-appraisal",
      "W:Analyzing (Ctrl+C to interrupt)"
    ])

    # Handle is now bound to the new tail entry id.
    expect(handle.entry_id).to eq(layout.entries.last.id)

    # Returned id is the business entry, NOT the rotated progress entry.
    expect(returned_id).to eq(layout.entries[1].id)

    # Operation order: remove old progress, append business, append fresh
    # progress. (This is the sequence that keeps every step a tail
    # operation in LayoutManager.)
    op_kinds = layout.calls.map(&:first)
    expect(op_kinds).to eq([:remove, :append, :append])
  end

  it "rotates an active progress that is no longer the tail (someone else appended)" do
    layout = RotationFakeLayout.new
    ctrl   = build_controller(layout)

    # Active progress, but a stray business entry already sits below it
    # (simulating any append path that bypassed the rotation logic — or
    # an out-of-order race we want to self-heal on the next append).
    progress_entry = layout.append_output("P:Analyzing… (5s)")
    layout.append_output("stray follow-up")
    handle = FakeHandle.new(entry_id: progress_entry)
    ctrl.instance_variable_get(:@progress_stack).push(handle)

    layout.calls.clear
    ctrl.append_output("hello")

    # Progress is now the tail again, the new business message sits
    # immediately above it, the stray follow-up is preserved in place.
    expect(layout.entries.map(&:content).last).to eq("W:Analyzing (Ctrl+C to interrupt)")
    expect(handle.entry_id).to eq(layout.entries.last.id)
    # Ops: remove old progress, append "hello", append fresh progress.
    expect(layout.calls.map(&:first)).to eq([:remove, :append, :append])
  end

  it "is a plain pass-through when no progress is active" do
    layout = RotationFakeLayout.new
    ctrl   = build_controller(layout)

    layout.append_output("first")
    layout.calls.clear

    ctrl.append_output("second")

    expect(layout.calls.map(&:first)).to eq([:append])
    expect(layout.entries.map(&:content)).to eq(["first", "second"])
  end

  it "is a plain pass-through when the active progress is detached (not the tail)" do
    layout = RotationFakeLayout.new
    ctrl   = build_controller(layout)

    # Simulate a handle whose entry was detached because a higher-priority
    # progress was pushed above it (Plan B stack semantics). entry_id is
    # nil, so there is nothing to rotate.
    handle = FakeHandle.new(entry_id: nil)
    ctrl.instance_variable_get(:@progress_stack).push(handle)

    ctrl.append_output("status update")

    expect(layout.calls.map(&:first)).to eq([:append])
    expect(handle.entry_id).to be_nil
  end
end
