# frozen_string_literal: true

require "securerandom"

module Clacky
  # UIInterface defines the standard interface between Agent/CLI and UI implementations.
  # All UI controllers (UIController, JsonUIController) must implement these methods.
  module UIInterface
    # === Output display ===
    # @param content [String] text portion of the assistant reply (file:// links stripped)
    # @param files   [Array<Hash>] extracted file refs: [{ name:, path:, inline: }]
    def show_assistant_message(content, files:, interim: false, created_at: nil); end
    def show_feedback_request(question, context, options, questions: nil); end
    def show_subagent_start(skill: nil, iterations: nil, cost_usd: nil); end
    def show_subagent_end; end
    def show_tool_call(name, args); end
    def show_tool_result(result); end
    def show_tool_stdout(lines); end
    def show_tool_error(error); end
    def show_tool_args(formatted_args); end
    def show_file_write_preview(path, is_new_file:); end
    def show_file_edit_preview(path); end
    def show_file_error(error_message); end
    def show_shell_preview(command); end
    def show_diff(old_content, new_content, max_lines: 50); end
    def show_token_usage(token_data); end

    # Broadcast the current standing-goal (/goal) state. `goal` is the
    # GoalState hash or nil. UIs that render goal progress override this.
    def show_goal_status(goal); end

    # Notify the UI that the agent changed its permission mode internally
    # (e.g. /goal auto-switches to auto_approve). UIs that render the mode
    # in a status bar override this.
    def update_permission_mode(mode); end
    def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false, cost_source: nil); end
    def append_output(content); end

    # === Status messages ===
    def show_info(message, prefix_newline: true); end
    def show_warning(message); end
    def show_error(message, code: nil, top_up_url: nil, raw_message: nil); end
    def show_success(message); end
    def log(message, level: :info); end

    # === Progress ===
    # Unified progress indicator with type-based display customization.
    # progress_type: "thinking" | "retrying" | "idle_compress" | custom
    # phase: "active" | "done"
    # metadata: extensible hash (e.g., {attempt: 3, total: 10} for retries)
    def show_progress(message = nil, prefix_newline: true, progress_type: "thinking", phase: "active", metadata: {}); end

    # Update the live "thinking" progress with streamed token counts.
    # This is *purely decorative*: it must NEVER start a new progress
    # indicator. If no thinking progress is currently active (e.g. during
    # idle compression, where only a quiet "Compressing..." progress is
    # live), the call is a no-op. UI2 overrides this; other UIs delegate
    # to show_progress.
    def stream_thinking_progress(input_tokens:, output_tokens:)
      show_progress(
        progress_type: "thinking",
        phase: "active",
        metadata: { input_tokens: input_tokens, output_tokens: output_tokens }
      )
    end

    # === Progress (v2: owned handles) ===
    #
    # Start a new progress indicator and return an owned handle. The caller
    # is responsible for finishing it — use +with_progress+ (below) whenever
    # possible to get ensure-based auto-close.
    #
    # @param message [String, nil] Initial progress message (nil picks a random thinking verb).
    # @param style [Symbol] :primary (foreground, yellow, bumps sessionbar)
    #   or :quiet (background, gray, no sessionbar change).
    # @param quiet_on_fast_finish [Boolean] When true, a finish under
    #   FAST_FINISH_THRESHOLD_SECONDS removes the progress line entirely
    #   (preferred for per-tool wrappers so fast tools don't leave a
    #   permanent "Executing foo… (0s)" log line). The default
    #   implementation ignores this flag — it only affects the native
    #   UI2::UIController + ProgressHandle path.
    # @return [#update, #finish, #cancel] a ProgressHandle-like object.
    #
    # Default implementation degrades gracefully to the old show_progress API
    # so UI implementations that haven't migrated still behave correctly.
    def start_progress(message: nil, style: :primary, quiet_on_fast_finish: false)
      _ = quiet_on_fast_finish # default impl doesn't honor fast-collapse
      progress_type = style == :primary ? "thinking" : "idle_compress"
      show_progress(message, progress_type: progress_type, phase: "active")
      LegacyProgressHandleAdapter.new(self, progress_type: progress_type)
    end

    # Run the given block with a progress indicator active. The handle is
    # always finished in an +ensure+ block — exceptions (including
    # AgentInterrupted) cannot leave the ticker or entry orphaned.
    #
    # @yieldparam handle the progress handle
    def with_progress(message: nil, style: :primary, quiet_on_fast_finish: false)
      handle = start_progress(
        message: message,
        style: style,
        quiet_on_fast_finish: quiet_on_fast_finish
      )
      begin
        yield handle
      ensure
        handle.finish
      end
    end

    # Minimal adapter that lets UIs without a native ProgressHandle still
    # participate in the new +with_progress+ API by delegating to the old
    # +show_progress(phase: ...)+ contract. UI2::UIController overrides
    # +start_progress+ directly with a native ProgressHandle, so this
    # adapter is only used by plain/json/web/channel UIs.
    class LegacyProgressHandleAdapter
      def initialize(ui, progress_type:)
        @ui = ui
        @progress_type = progress_type
        @closed = false
      end

      def update(message: nil, metadata: nil)
        return if @closed
        @ui.show_progress(message, progress_type: @progress_type, phase: "active", metadata: metadata || {})
      end

      def finish(final_message: nil)
        return if @closed
        @closed = true
        @ui.show_progress(final_message, progress_type: @progress_type, phase: "done")
      end
      alias_method :cancel, :finish
    end

    # === State updates ===
    def update_sessionbar(tasks: nil, cost: nil, cost_source: nil, status: nil, latency: nil); end
    def update_todos(todos); end
    def set_working_status; end
    def set_idle_status; end

    # === Blocking interaction ===
    def request_confirmation(message, default: true); end

    # Auto-approve countdown for ask_user. Shows a live countdown
    # and lets the user press a key to take over and answer. Returns :timeout
    # when no one intervenes (agent should auto-decide and continue), or a
    # feedback string / "" when the user steps in. Non-interactive UIs (web,
    # json, channel) have no human watching a TTY, so they default to :timeout.
    def request_feedback_with_countdown(seconds: 10)
      :timeout
    end

    # === Input control (CLI layer) ===
    def clear_input; end
    def set_input_tips(message, type: :info); end

    # === Path redaction (for encrypted brand skill tmpdirs) ===
    # === Lifecycle ===
    def stop(clear_screen: false); end

    # === Custom events (extension bus) ===
    # Push an arbitrary typed event to the UI transport. Streaming UIs (web,
    # json) override this; UIs with no event channel (CLI, null) drop it.
    #
    # Extensions must namespace `type` as "ext.<extension>.<event>" so custom
    # events never collide with the built-in protocol. The web UI forwards
    # namespaced events straight to the `Clacky.ext` bus, where a subscriber
    # receives them under that same name.
    def emit(type, **data); end

    # === Phase grouping (optional, web UI uses this to fold subagent runs) ===
    # Begin a logical phase. Events emitted between phase_start and phase_end
    # carry the phase_id so the UI can group them visually.
    # Returns the phase_id (caller is responsible for passing it to phase_end).
    def phase_start(kind:, label: nil, concurrent: false)
      SecureRandom.uuid
    end

    def phase_end(phase_id, summary: nil); end

    # Run block within a phase. Always closes via ensure.
    def with_phase(kind:, label: nil, concurrent: false)
      pid = phase_start(kind: kind, label: label, concurrent: concurrent)
      begin
        yield pid
      ensure
        phase_end(pid)
      end
    end
  end
end
