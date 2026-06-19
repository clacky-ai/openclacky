# frozen_string_literal: true

require "monitor"

module Clacky
  module UI2
    # An *owned* progress indicator.
    #
    # Why this exists
    # ---------------
    # The previous design had a single, globally-shared spinner slot on
    # UiController (`@progress_id` / `@progress_thread` / `@progress_message`
    # / `@progress_start_time`). Every caller — Agent#run, Agent#think,
    # LlmCaller retry, idle compression, MemoryUpdater — wrote into the
    # same slot and hoped to remember to close it. When control flow was
    # interrupted (user types a new message during idle compression,
    # AgentInterrupted is raised) a ticker thread would be left running
    # and a new spinner would reuse the same entry, producing two
    # concurrent tickers repainting the same line in different colors.
    #
    # In the new design each caller owns a ProgressHandle. The handle
    # encapsulates:
    #
    # - its own OutputBuffer entry id (may become nil while another
    #   handle is on top — see "Stack semantics" below);
    # - its own ticker thread (exactly one per handle, stopped and
    #   joined on +finish+);
    # - its own message, style, start time;
    #
    # Owners (UiController) keep a stack of live handles and follow the
    # protocol below.
    #
    # Owner protocol
    # --------------
    # An "owner" must respond to three methods:
    #
    #   register_progress(handle) -> Integer (entry_id) | nil
    #     Called exactly once when the handle starts. The owner pushes
    #     the handle onto its stack, creates an OutputBuffer entry, and
    #     returns that entry id. Before pushing, the owner may detach
    #     the previous top-of-stack (Plan B: its entry is removed from
    #     the buffer until the new top finishes).
    #
    #   unregister_progress(handle, final_frame:) -> void
    #     Called exactly once when the handle finishes. The owner pops
    #     the handle from its stack, renders +final_frame+ into the
    #     entry (or removes the entry if +final_frame+ is nil), and may
    #     reattach the new top-of-stack if one exists.
    #
    #   render_frame(handle, frame) -> void
    #     Called by the ticker (and by +update+) on every paint. The
    #     owner is responsible for ignoring the call if +handle+ is not
    #     currently top-of-stack — the handle itself does NOT know about
    #     the stack.
    #
    # Stack semantics (Plan B)
    # ------------------------
    # When a new handle is pushed on top of an existing one, the lower
    # handle's OutputBuffer entry is removed (owner calls
    # +__detach_entry!+ on it). When the new top finishes, the owner
    # re-creates an entry for the lower handle and calls
    # +__reattach_entry!+ with the new id. This keeps the visible output
    # clean: exactly one progress line on screen at a time, and no
    # visual "stacking" of frozen progress lines.
    #
    # Thread safety
    # -------------
    # The handle uses a Monitor (reentrant) to serialize state changes
    # between the caller thread and the ticker thread. Public methods
    # (+start+, +update+, +finish+) are safe to call from any thread.
    class ProgressHandle
      # Default tick interval (seconds). Matches the old global spinner
      # cadence. Tests may pass a smaller interval for speed.
      DEFAULT_TICK_INTERVAL = 0.25

      # Style hint for the renderer. The owner decides what colors to use;
      # the handle only forwards the hint as part of the frame metadata
      # so the renderer can pick between e.g. yellow "working" and gray
      # "quiet" palettes.
      #
      #   :primary  — foreground task, should also update sessionbar
      #   :quiet    — background task (idle compression, retries); does
      #               NOT bump sessionbar to 'working'
      VALID_STYLES = %i[primary quiet].freeze

      attr_reader :entry_id, :message, :style, :start_time

      # Threshold (seconds) below which a +quiet_on_fast_finish+ handle
      # collapses its final frame — i.e. the progress line is REMOVED
      # from the output buffer instead of being kept as a permanent
      # "Executing foo… (0s)" log line. Operations that finish this fast
      # didn't need a spinner in the first place; keeping the final
      # frame would be visual noise.
      FAST_FINISH_THRESHOLD_SECONDS = 2

      # Show "Thinking for Ns" once the gap since the last LLM stream
      # chunk reaches this many seconds. Bedrock often pauses 5–18s
      # while generating large content blocks (long tool_use JSON in
      # particular); without this hint users assume the agent is stuck.
      IDLE_HINT_THRESHOLD_SECONDS = 2

      # @param owner [#register_progress, #unregister_progress, #render_frame]
      # @param message [String] Initial progress message.
      # @param style [Symbol] :primary or :quiet (see VALID_STYLES).
      # @param tick_interval [Float] Seconds between auto-renders.
      # @param quiet_on_fast_finish [Boolean] When true and the elapsed
      #   time on +finish+ is under FAST_FINISH_THRESHOLD_SECONDS, the
      #   owner is told to remove the progress entry (+final_frame: nil+)
      #   instead of committing a permanent final frame. This is the
      #   preferred mode for tool execution wrappers, where fast tools
      #   (edit, write, read) don't need a lingering "Executing edit…
      #   (0s)" line after completion.
      # @param clock [#call] Test hook: returns current Time (default Time.now).
      def initialize(owner:, message:, style: :primary, tick_interval: DEFAULT_TICK_INTERVAL, quiet_on_fast_finish: false, clock: -> { Time.now })
        unless VALID_STYLES.include?(style)
          raise ArgumentError, "unknown progress style: #{style.inspect} (valid: #{VALID_STYLES.inspect})"
        end

        @owner                = owner
        @message              = message.to_s
        @style                = style
        @tick_interval        = tick_interval
        @quiet_on_fast_finish = quiet_on_fast_finish
        @clock                = clock

        @entry_id      = nil
        @start_time    = nil
        @ticker        = nil
        @state         = :fresh     # :fresh → :running → :closed
        @unregistered  = false
        @metadata      = {}
        @last_chunk_at = nil
        @monitor       = Monitor.new
      end

      # Start rendering. Registers with the owner (allocating an entry id
      # and pushing onto its stack) and launches the ticker thread.
      #
      # @return [self]
      def start
        @monitor.synchronize do
          return self unless @state == :fresh

          @state         = :running
          @start_time    = @clock.call
          @last_chunk_at = @start_time
          @entry_id      = @owner.register_progress(self)
        end

        # Fire one initial frame synchronously so the user sees the
        # spinner immediately — no "blank line for half a second" bug.
        render_now

        start_ticker
        self
      end

      # Change the message or metadata mid-flight. Safe to call from any
      # thread. Triggers an immediate re-render (if top-of-stack; the
      # owner will ignore the call otherwise).
      #
      # @param message [String, nil]
      # @param metadata [Hash] Renderer-specific extras (e.g. retry counts).
      def update(message: nil, metadata: nil)
        @monitor.synchronize do
          return if @state != :running
          @message  = message.to_s if message
          if metadata
            @metadata = metadata
            @last_chunk_at = @clock.call
          end
        end
      end

      # Stop the ticker, render one final frame, and unregister from the
      # owner. Idempotent and crash-safe — if a previous finish was
      # interrupted (e.g. Thread#raise(AgentInterrupted) hit between
      # +stop_ticker+ and +unregister_progress+), a follow-up finish
      # will still complete the unregister so the handle does not stay
      # orphaned on the owner's progress stack.
      #
      # @param final_message [String, nil] Optional override for the last
      #   frame. If nil, the handle composes "<message>… (<elapsed>s)".
      def finish(final_message: nil)
        Clacky::Logger.warn("[ph_debug] finish_entry", oid: object_id, state: @state, unreg: @unregistered, msg: @message, eid: @entry_id)
        snapshot = @monitor.synchronize do
          return if @unregistered
          first_close = @state == :running
          @state = :closed if first_close
          {
            first_close: first_close,
            message: final_message || @message,
            elapsed: elapsed_seconds,
          }
        end

        stop_ticker
        final_frame =
          if @quiet_on_fast_finish && snapshot[:elapsed] < FAST_FINISH_THRESHOLD_SECONDS
            nil
          else
            compose_final_frame(snapshot[:message], snapshot[:elapsed])
          end
        Clacky::Logger.warn("[ph_debug] finish_unregister", oid: object_id, eid: @entry_id, first_close: snapshot[:first_close], final_frame: final_frame.to_s[0, 200])
        @owner.unregister_progress(self, final_frame: final_frame)
        @monitor.synchronize { @unregistered = true }
        Clacky::Logger.warn("[ph_debug] finish_done", oid: object_id)
      end
      alias_method :cancel, :finish

      # True while the ticker thread is alive.
      def ticker_alive?
        t = @ticker
        !!(t && t.alive?)
      end

      # True between +start+ and +finish+.
      def running?
        @monitor.synchronize { @state == :running }
      end

      # Compose the current visual frame. The owner gets this string via
      # +render_frame+ and is responsible for writing it into the entry.
      def current_frame
        @monitor.synchronize do
          compose_frame(@message, elapsed_seconds, @metadata, idle_seconds)
        end
      end

      # ---- owner-facing hooks (Plan B stack machinery) ----------------
      #
      # These double-underscore methods are part of the owner protocol.
      # They are NOT meant for general callers.

      # Owner calls this when this handle is being pushed below a new
      # top. The handle loses its OutputBuffer entry until restored.
      def __detach_entry!
        @monitor.synchronize { @entry_id = nil }
      end

      # Owner calls this when this handle becomes top-of-stack again
      # (the handle above finished). A fresh entry id is supplied.
      def __reattach_entry!(new_entry_id)
        @monitor.synchronize { @entry_id = new_entry_id }
        render_now
      end

      # Like __reattach_entry! but skips the render_now hop. Used by the
      # owner when it has just painted a frame into the new entry itself
      # (e.g. while rotating the handle to remain at the buffer tail) and
      # is still inside its own synchronization — calling render_now there
      # would re-enter the owner's mutex.
      def __rebind_entry!(new_entry_id)
        @monitor.synchronize { @entry_id = new_entry_id }
      end

      # Test hook: force a synchronous render regardless of tick cadence.
      def __force_render!
        render_now
      end

      private def start_ticker
        @ticker = Thread.new do
          Thread.current.name = "progress-ticker-#{object_id}"
          begin
            loop do
              sleep @tick_interval
              break if @monitor.synchronize { @state != :running }
              render_now
            end
          rescue StandardError
            # Ticker must never crash the process — the caller's main
            # thread still owns the real control flow.
          end
        end
      end

      private def stop_ticker
        t = @ticker
        return unless t
        # The loop checks @state on each iteration, so once we're
        # :closed the next wake-up exits cleanly. Give it 1s; if
        # something is stuck, kill as a last resort.
        joined = t.join(1.0)
        t.kill unless joined
        @ticker = nil
      end

      private def render_now
        frame = current_frame
        @owner.render_frame(self, frame)
      rescue StandardError
        # Rendering must never propagate.
      end

      private def elapsed_seconds
        return 0 unless @start_time
        (@clock.call - @start_time).to_i
      end

      # Seconds since the last metadata update (i.e. the last LLM stream
      # chunk that carried token info). Used to surface "Thinking for Ns"
      # in the live frame so users can see the agent isn't stuck even
      # when token counts plateau during long Bedrock content blocks.
      private def idle_seconds
        return 0 unless @last_chunk_at
        (@clock.call - @last_chunk_at).to_i
      end

      # Live-frame format:
      #   "<message>… (<elapsed>s · ↓N tokens · reasoning…)"
      # The "reasoning" tail only appears once tokens have started
      # streaming AND the gap since the last chunk reaches the threshold
      # — signalling the model is between tool_use blocks doing extended
      # thinking. No seconds shown there to avoid duplicating elapsed;
      # animated dots (1→2→3) provide the "still alive" cue.
      private def compose_frame(message, elapsed, metadata, idle = 0)
        head = message.to_s
        if metadata && (attempt = metadata[:attempt]) && (total = metadata[:total])
          head = "#{head} [#{attempt}/#{total}]"
        end

        token_part = metadata && format_token_progress(metadata)

        suffix_parts = []
        suffix_parts << "#{elapsed}s" if elapsed > 0
        suffix_parts << token_part if token_part
        if token_part && idle >= IDLE_HINT_THRESHOLD_SECONDS
          suffix_parts << "reasoning #{spinner_frame} "
        end

        return "#{head}…" if suffix_parts.empty?
        "#{head}… (#{suffix_parts.join(" · ")})"
      end

      SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
      SPINNER_INTERVAL_MS = 250

      private def spinner_frame
        ms = (@clock.call.to_f * 1000).to_i
        SPINNER_FRAMES[(ms / SPINNER_INTERVAL_MS) % SPINNER_FRAMES.length]
      end

      # Render LLM streaming token counts as "↑1.2k ↓234 tokens".
      # When input_tokens is unknown (e.g. OpenAI-compat streaming where
      # prompt_tokens only arrives in the final frame), shows "↑—" so the
      # column doesn't flicker between absent / present.
      private def format_token_progress(metadata)
        output = metadata[:output_tokens]
        return nil if output.nil? || output.to_i <= 0
        "↓ #{compact_count(output.to_i)} tokens"
      end

      private def compact_count(n)
        return n.to_s if n < 1000
        if n < 1_000_000
          k = n / 1000.0
          k >= 10 ? "#{k.to_i}k" : "%.1fk" % k
        else
          m = n / 1_000_000.0
          m >= 10 ? "#{m.to_i}M" : "%.1fM" % m
        end
      end

      # Final frame (used by +finish+). Same as +compose_frame+ but we
      # always include elapsed time so the last line carries a duration.
      private def compose_final_frame(message, elapsed)
        "#{message}… (#{elapsed}s)"
      end
    end
  end
end
