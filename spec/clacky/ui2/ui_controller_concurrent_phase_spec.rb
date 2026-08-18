# frozen_string_literal: true

require "clacky/ui2/ui_controller"
require "clacky/ui2/progress_handle"
require "clacky/ui2/view_renderer"

# Concurrent phases (parallel subagents) have no equivalent in a line-oriented
# terminal: the web UI gives each one its own live card, but the CLI has a
# single output stream, so N interleaved transcripts are unreadable. The CLI
# therefore collapses every concurrent phase into ONE shared progress line that
# tracks each label's state, and suppresses their transcripts entirely.
RSpec.describe Clacky::UI2::UIController, "concurrent phase output" do
  class ConcurrentFakeLayout
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

  def build_controller(verbose: false)
    layout = ConcurrentFakeLayout.new
    ctrl = Clacky::UI2::UIController.allocate
    ctrl.instance_variable_set(:@layout, layout)
    ctrl.instance_variable_set(:@renderer, Clacky::UI2::ViewRenderer.new)
    ctrl.instance_variable_set(:@progress_mutex, Mutex.new)
    ctrl.instance_variable_set(:@progress_stack, [])
    ctrl.instance_variable_set(:@config, Struct.new(:verbose).new(verbose))
    ctrl.instance_variable_set(:@stdout_lines, [])
    ctrl.define_singleton_method(:update_sessionbar) { |**| }
    ctrl.define_singleton_method(:update_entry) { |id, c| @layout.update_entry(id, c) }
    ctrl.define_singleton_method(:remove_entry) { |id| @layout.remove_entry(id) }
    [ctrl, layout]
  end

  after { Thread.current[:clacky_concurrent_phase] = nil }

  it "keeps all parallel phases on a single shared line" do
    ctrl, layout = build_controller
    a = ctrl.phase_start(kind: "fanout_subagent", label: "code-explorer", concurrent: true)
    b = ctrl.phase_start(kind: "fanout_subagent", label: "media-gen", concurrent: true)
    c = ctrl.phase_start(kind: "fanout_subagent", label: "case-research", concurrent: true)

    expect(layout.visible.size).to eq(1)
    line = layout.visible.first
    expect(line).to include("code-explorer")
    expect(line).to include("media-gen")
    expect(line).to include("case-research")

    [a, b, c].each { |pid| ctrl.phase_end(pid) }
  end

  it "shows completion progress as each phase finishes" do
    ctrl, layout = build_controller
    a = ctrl.phase_start(kind: "fanout_subagent", label: "alpha", concurrent: true)
    b = ctrl.phase_start(kind: "fanout_subagent", label: "beta", concurrent: true)

    expect(layout.visible.first).to include("0/2")

    ctrl.phase_end(a)
    expect(layout.visible.first).to include("1/2")

    ctrl.phase_end(b)
    expect(layout.text).to include("2 parallel tasks done")
  end

  it "suppresses the interleaved transcripts of parallel subagents" do
    ctrl, layout = build_controller
    a = ctrl.phase_start(kind: "fanout_subagent", label: "alpha", concurrent: true)

    ctrl.show_tool_call("read", { "path" => "a.rb" })
    ctrl.show_assistant_message("chatter from subagent", files: nil)
    handle = ctrl.start_progress(message: "Thinking hard", style: :primary)
    handle.finish

    expect(layout.visible.size).to eq(1)
    expect(layout.text).not_to include("chatter from subagent")
    ctrl.phase_end(a)
  end

  it "leaves no progress tombstones behind after the batch" do
    ctrl, layout = build_controller
    pids = 3.times.map do |i|
      ctrl.phase_start(kind: "fanout_subagent", label: "task#{i}", concurrent: true)
    end

    pids.each do |pid|
      Thread.current[:clacky_concurrent_phase] = pid
      5.times do
        h = ctrl.start_progress(message: "Ruminating", style: :primary)
        h.finish
      end
    end
    Thread.current[:clacky_concurrent_phase] = nil

    pids.each { |pid| ctrl.phase_end(pid) }

    expect(layout.text).not_to include("Ruminating")
    expect(layout.visible.size).to eq(1)
  end

  it "falls back to full per-phase banners when verbose is on" do
    ctrl, layout = build_controller(verbose: true)
    pid = ctrl.phase_start(kind: "fanout_subagent", label: "alpha", concurrent: true)

    expect(layout.text).to include("▼ alpha")
    ctrl.phase_end(pid)
    expect(layout.text).to include("▲ alpha done")
  end

  it "still folds chore phases independently of concurrent ones" do
    ctrl, layout = build_controller
    chore = ctrl.phase_start(kind: "memory_update", label: "Updating long-term memory")
    ctrl.show_tool_call("read", {})
    ctrl.phase_end(chore, summary: "1 memory updated")

    expect(layout.text).to include("1 memory updated")
  end

  it "survives phases ending from their own threads" do
    ctrl, layout = build_controller
    pids = Queue.new

    threads = 4.times.map do |i|
      Thread.new do
        pid = ctrl.phase_start(kind: "fanout_subagent", label: "t#{i}", concurrent: true)
        ctrl.show_assistant_message("noise", files: nil)
        pids << pid
        ctrl.phase_end(pid)
      end
    end
    threads.each(&:join)

    expect(pids.size).to eq(4)
    expect(layout.text).not_to include("noise")
    expect(layout.text).to include("parallel task")
  end
end
