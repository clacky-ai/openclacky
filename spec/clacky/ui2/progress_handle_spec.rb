# frozen_string_literal: true

require "clacky/ui2/progress_handle"

# ProgressHandle is an *owned* progress indicator: the caller creates one,
# the handle takes responsibility for its ticker thread, its OutputBuffer
# entry, and its lifecycle. When the caller finishes (or an exception
# escapes a with_progress block), the handle is guaranteed to release all
# resources — no more orphan ticker threads writing into a slot that now
# belongs to someone else.
#
# To test the handle in isolation we use a tiny fake "owner" that records
# the bookkeeping calls the handle is expected to make.
RSpec.describe Clacky::UI2::ProgressHandle do
  # A minimal stand-in for UiController's internal protocol. It implements
  # the three methods a handle needs to talk to its owner, and records a
  # trace for assertions.
  let(:owner) { FakeOwner.new }

  class FakeOwner
    attr_reader :events, :stack

    def initialize
      @events = []
      @stack = []
      @next_entry_id = 100
      @mutex = Mutex.new
    end

    # Called by handle.start — returns an entry id if this handle should
    # render (i.e. it's now top-of-stack); nil means "you're not visible".
    def register_progress(handle)
      @mutex.synchronize do
        # B-scheme: if there's a previous top, it loses its entry.
        if (prev = @stack.last)
          @events << [:hide, prev.object_id]
          prev.__detach_entry!
        end
        @stack.push(handle)
        entry_id = @next_entry_id
        @next_entry_id += 1
        @events << [:register, handle.object_id, entry_id]
        entry_id
      end
    end

    # Called by handle.finish / cancel.
    def unregister_progress(handle, final_frame:)
      @mutex.synchronize do
        @events << [:unregister, handle.object_id, final_frame]
        @stack.delete(handle)
        # B-scheme: when a handle on top finishes, the one below it (if
        # any) gets re-attached and starts rendering again.
        if (restored = @stack.last)
          new_entry_id = @next_entry_id
          @next_entry_id += 1
          @events << [:restore, restored.object_id, new_entry_id]
          restored.__reattach_entry!(new_entry_id)
        end
      end
    end

    # Called by handle on each tick (and on update). No-op if not top.
    def render_frame(handle, frame)
      @mutex.synchronize do
        return unless @stack.last == handle
        @events << [:render, handle.object_id, frame]
      end
    end

    def top?
      @mutex.synchronize { @stack.last }
    end
  end

  # ---------------------------------------------------------------------------
  # lifecycle: start + finish
  # ---------------------------------------------------------------------------
  describe "#start / #finish" do
    it "registers itself with the owner and is assigned an entry id" do
      h = described_class.new(owner: owner, message: "Working", style: :primary)
      h.start
      expect(h.entry_id).to eq(100)
      expect(owner.events.first).to eq([:register, h.object_id, 100])
      h.finish
    end

    it "unregisters and stops its ticker on finish" do
      h = described_class.new(owner: owner, message: "Working", style: :primary)
      h.start
      h.finish
      expect(h.ticker_alive?).to be(false)
      expect(owner.events.map(&:first)).to include(:unregister)
    end

    it "is safe to call finish twice" do
      h = described_class.new(owner: owner, message: "Working", style: :primary)
      h.start
      h.finish
      expect { h.finish }.not_to raise_error
    end

    it "completes the unregister on a follow-up finish when the first was interrupted between stop_ticker and unregister_progress" do
      raising_owner = Class.new do
        attr_reader :register_calls, :unregister_calls, :raise_on_first

        def initialize
          @register_calls = 0
          @unregister_calls = 0
          @raise_on_first = true
        end

        def register_progress(_handle)
          @register_calls += 1
          1
        end

        def unregister_progress(_handle, final_frame:)
          _ = final_frame
          @unregister_calls += 1
          if @raise_on_first
            @raise_on_first = false
            raise Interrupt, "simulated Thread#raise during unregister"
          end
        end

        def render_frame(_handle, _frame); end
      end.new

      h = described_class.new(owner: raising_owner, message: "Executing edit", style: :quiet, quiet_on_fast_finish: true)
      h.start
      expect { h.finish }.to raise_error(Interrupt)
      expect(raising_owner.unregister_calls).to eq(1)

      h.finish
      expect(raising_owner.unregister_calls).to eq(2)
      expect(h.ticker_alive?).to be(false)

      h.finish
      expect(raising_owner.unregister_calls).to eq(2)
    end

    it "passes a final frame (with elapsed time) to the owner on finish" do
      h = described_class.new(owner: owner, message: "Saving", style: :primary)
      h.start
      h.finish
      unreg = owner.events.find { |e| e.first == :unregister }
      expect(unreg[2]).to be_a(String)
      expect(unreg[2]).to include("Saving")
    end
  end

  # ---------------------------------------------------------------------------
  # ensure-path: exception must not leak the handle
  # ---------------------------------------------------------------------------
  describe "ensure-path semantics (what a with_progress wrapper guarantees)" do
    it "finishes cleanly when the caller raises" do
      h = described_class.new(owner: owner, message: "Thinking", style: :primary)
      h.start
      begin
        raise "boom"
      rescue StandardError
        h.finish
      end
      expect(h.ticker_alive?).to be(false)
      expect(owner.events.map(&:first)).to include(:unregister)
    end
  end

  # ---------------------------------------------------------------------------
  # stack semantics (Plan B: non-top handles lose their entry)
  # ---------------------------------------------------------------------------
  describe "nested handles (Plan B: remove + restore)" do
    it "hides the lower handle when a new one is pushed" do
      outer = described_class.new(owner: owner, message: "Compressing", style: :quiet).start
      inner = described_class.new(owner: owner, message: "Thinking",    style: :primary).start

      hide_event = owner.events.find { |e| e.first == :hide }
      expect(hide_event).not_to be_nil
      expect(hide_event[1]).to eq(outer.object_id)
      expect(outer.entry_id).to be_nil

      inner.finish
      outer.finish
    end

    it "restores the lower handle when the top one finishes" do
      outer = described_class.new(owner: owner, message: "Compressing", style: :quiet).start
      inner = described_class.new(owner: owner, message: "Thinking",    style: :primary).start
      inner.finish

      restore_event = owner.events.find { |e| e.first == :restore }
      expect(restore_event).not_to be_nil
      expect(restore_event[1]).to eq(outer.object_id)
      expect(outer.entry_id).not_to be_nil

      outer.finish
    end

    it "only the top handle receives render_frame events" do
      outer = described_class.new(owner: owner, message: "Compressing", style: :quiet).start
      inner = described_class.new(owner: owner, message: "Thinking",    style: :primary).start

      # Force a manual render on each — owner.render_frame must be a no-op
      # for the non-top handle.
      owner.events.clear
      outer.__force_render!
      inner.__force_render!

      rendered_ids = owner.events.select { |e| e.first == :render }.map { |e| e[1] }
      expect(rendered_ids).to eq([inner.object_id])

      inner.finish
      outer.finish
    end
  end

  # ---------------------------------------------------------------------------
  # ticker thread lifecycle
  # ---------------------------------------------------------------------------
  describe "ticker thread" do
    it "starts a ticker thread on start" do
      h = described_class.new(owner: owner, message: "Thinking", style: :primary, tick_interval: 0.05)
      h.start
      expect(h.ticker_alive?).to be(true)
      h.finish
    end

    it "ticker writes frames while alive (top-of-stack)" do
      h = described_class.new(owner: owner, message: "Thinking", style: :primary, tick_interval: 0.02)
      h.start
      sleep 0.1
      render_events = owner.events.select { |e| e.first == :render }
      expect(render_events.size).to be >= 1
      h.finish
    end

    it "ticker joins within a small timeout on finish" do
      h = described_class.new(owner: owner, message: "Thinking", style: :primary, tick_interval: 0.02)
      h.start
      t0 = Time.now
      h.finish
      expect(Time.now - t0).to be < 1.0
      expect(h.ticker_alive?).to be(false)
    end
  end

  # ---------------------------------------------------------------------------
  # update: change message / metadata mid-flight
  # ---------------------------------------------------------------------------
  describe "#update" do
    it "updates the message visible in the next composed frame" do
      h = described_class.new(owner: owner, message: "Thinking", style: :primary).start
      h.update(message: "Retrying (1/3)")
      expect(h.current_frame).to include("Retrying")
      h.finish
    end

    it "is a no-op after finish" do
      h = described_class.new(owner: owner, message: "Thinking", style: :primary).start
      h.finish
      owner.events.clear
      h.update(message: "too late")
      expect(owner.events).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # quiet_on_fast_finish: fast-finishing wrappers (tool execution) collapse
  # their progress line to `nil` so no permanent "Executing edit… (0s)" log
  # is left on screen. Slow finishers still get a real final frame.
  # ---------------------------------------------------------------------------
  describe "#finish with quiet_on_fast_finish: true" do
    # Controllable clock so we can simulate elapsed time deterministically.
    # Each call to the lambda returns the next timestamp.
    let(:now) { Time.at(1_700_000_000) }

    it "passes final_frame: nil when elapsed is under the threshold" do
      times = [now, now + 0.5] # start → finish: 0.5s elapsed → fast
      clock = -> { times.shift || now + 0.5 }
      h = described_class.new(
        owner: owner,
        message: "Executing edit",
        style: :quiet,
        quiet_on_fast_finish: true,
        clock: clock
      )
      h.start
      h.finish

      unreg = owner.events.find { |e| e.first == :unregister }
      expect(unreg).not_to be_nil
      expect(unreg[2]).to be_nil # owner interprets nil as remove_entry
    end

    it "still passes a final frame when elapsed exceeds the threshold" do
      # 3s elapsed — over FAST_FINISH_THRESHOLD_SECONDS (2s).
      times = [now, now + 3]
      clock = -> { times.shift || now + 3 }
      h = described_class.new(
        owner: owner,
        message: "Running command",
        style: :quiet,
        quiet_on_fast_finish: true,
        clock: clock
      )
      h.start
      h.finish

      unreg = owner.events.find { |e| e.first == :unregister }
      expect(unreg[2]).to be_a(String)
      expect(unreg[2]).to include("Running command")
      expect(unreg[2]).to include("3s")
    end

    it "default (quiet_on_fast_finish: false) always preserves the final frame even on instant finish" do
      times = [now, now + 0.1] # instant
      clock = -> { times.shift || now + 0.1 }
      h = described_class.new(
        owner: owner,
        message: "Compressing",
        style: :quiet,
        clock: clock
      )
      h.start
      h.finish

      unreg = owner.events.find { |e| e.first == :unregister }
      expect(unreg[2]).to be_a(String)
      expect(unreg[2]).to include("Compressing")
    end
  end

  describe "token-count metadata rendering" do
    it "appends ↓N tokens when output_tokens is positive" do
      h = described_class.new(owner: owner, message: "Thinking", tick_interval: 999)
      h.start
      h.update(metadata: { input_tokens: 12, output_tokens: 7 })

      expect(h.current_frame).to include("↓ 7 tokens")
      h.finish
    end

    it "compacts thousands as 1.2k and 10k+" do
      h = described_class.new(owner: owner, message: "Thinking", tick_interval: 999)
      h.start
      h.update(metadata: { input_tokens: 1234, output_tokens: 12_345 })

      expect(h.current_frame).to include("↓ 12k tokens")
      h.finish
    end

    it "omits token suffix when only attempt/total metadata is present" do
      h = described_class.new(owner: owner, message: "Retrying", tick_interval: 999)
      h.start
      h.update(metadata: { attempt: 2, total: 3 })

      frame = h.current_frame
      expect(frame).to include("[2/3]")
      expect(frame).not_to include("↓")
      h.finish
    end

    it "renders elapsed and tokens inside a single dot-separated parenthetical" do
      clock_value = 0.0
      clock = -> { clock_value }
      h = described_class.new(owner: owner, message: "Computing", tick_interval: 999, clock: clock)
      h.start
      clock_value = 12.0
      h.update(metadata: { input_tokens: 0, output_tokens: 132 })

      expect(h.current_frame).to eq("Computing… (12s · ↓ 132 tokens)")
      h.finish
    end

    it "appends a Braille spinner + 'reasoning' once the gap since last update reaches the threshold" do
      clock_value = 0.0
      clock = -> { clock_value }
      h = described_class.new(owner: owner, message: "Computing", tick_interval: 999, clock: clock)
      h.start
      clock_value = 1.0
      h.update(metadata: { input_tokens: 0, output_tokens: 50 })

      # Spinner advances every 250ms across 10 Braille frames.
      # 5000/250=20, 20%10=0 → frame 0 (⠋).
      clock_value = 5.000; expect(h.current_frame).to include("reasoning ⠋")
      clock_value = 5.250; expect(h.current_frame).to include("reasoning ⠙")
      clock_value = 5.500; expect(h.current_frame).to include("reasoning ⠹")

      frame = h.current_frame
      expect(frame).to include("↓ 50 tokens")
      expect(frame).not_to match(/\d+s · [⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/) # no second-counter inside reasoning
      h.finish
    end

    it "omits the reasoning tail before any tokens have arrived" do
      clock_value = 0.0
      clock = -> { clock_value }
      h = described_class.new(owner: owner, message: "Computing", tick_interval: 999, clock: clock)
      h.start
      clock_value = 30.0
      expect(h.current_frame).not_to include("reasoning")
      h.finish
    end
  end
end
