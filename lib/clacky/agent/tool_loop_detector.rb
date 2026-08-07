# frozen_string_literal: true

module Clacky
  class Agent
    # ToolLoopDetector keeps the agent from burning its whole context window
    # on a repeating sequence of identical tool calls.
    #
    # When a model cannot synthesize partial results into a final answer it
    # tends to re-issue the *same* tool calls (same name + same arguments)
    # turn after turn and never converge. Without a guard the loop only stops
    # once the context window is exhausted — wasting tokens and never yielding
    # a useful reply (see issue #440).
    #
    # Design:
    #   * A sliding window holds the last LOOP_WINDOW_SIZE tool-call signatures
    #     (`name:normalized_args`). Execution is NEVER blocked, so legitimate
    #     repeats such as `git status` → edit → `git status` keep working.
    #   * When a turn's signatures already appear in the window an escalating
    #     nudge is injected as a system message (notice → warning → critical)
    #     urging the model to reason from the results it already has.
    #   * After LOOP_BREAK_LIMIT consecutive unresolved repetitions the loop is
    #     force-broken with a final, user-visible message.
    module ToolLoopDetector
      # Number of recent tool-call signatures retained for comparison. Sized to
      # span a couple of typical multi-call turns so a periodic repeat (e.g.
      # the 4-call cycle reported in #440) is caught on its second occurrence.
      LOOP_WINDOW_SIZE = 8

      # Consecutive repeated turns after which the agent loop is force-broken.
      LOOP_BREAK_LIMIT = 4

      TOOL_LOOP_MESSAGES = {
        notice: "You just repeated tool calls whose results are already in the conversation. " \
                "Re-reading the same files or re-running the same commands adds no new information. " \
                "Synthesize your answer from what you already have.",
        warning: "WARNING: you are repeating the same tool calls without making progress and the " \
                 "results are unchanged. Stop calling these tools and write your final answer using " \
                 "the information already gathered.",
        critical: "CRITICAL: this is the third consecutive turn of identical tool calls. " \
                  "Do NOT issue any more tool calls. Provide your final response now based on the " \
                  "results already in the conversation."
      }.freeze

      # Build a stable signature for a single tool call so that structurally
      # identical calls (same name + same effective arguments) compare equal
      # regardless of key type (symbol vs string) or JSON formatting.
      private def tool_call_signature(call)
        name = (call[:name] || call.dig(:function, :name)).to_s
        args = call[:arguments]
        parsed = begin
          args.is_a?(String) ? JSON.parse(args) : args
        rescue JSON::ParserError
          args
        end
        "#{name}:#{normalize_for_signature(parsed)}"
      end

      # Produce a canonical string for a value, sorting object keys recursively
      # so key order never affects the signature.
      private def normalize_for_signature(value)
        case value
        when Hash
          "{" + value.sort.map { |k, v| "#{normalize_for_signature(k.to_s)}:#{normalize_for_signature(v)}" }.join(",") + "}"
        when Array
          "[" + value.map { |v| normalize_for_signature(v) }.join(",") + "]"
        else
          value.to_s
        end
      end

      # Record this turn's tool-call signatures against the sliding window and
      # return a signal describing the detected repetition:
      #   nil       — no repetition (the turn introduced new tool calls)
      #   :notice   — first repeated turn
      #   :warning  — second consecutive repeated turn
      #   :critical — third consecutive repeated turn
      #   :break    — LOOP_BREAK_LIMIT reached; the caller should stop the loop
      private def detect_tool_calls_loop(tool_calls)
        current = Array(tool_calls).map { |c| tool_call_signature(c) }
        repeated = current.count { |sig| @recent_tool_signatures.include?(sig) }

        if repeated.positive?
          @unresolved_loop_streak += 1
        else
          @unresolved_loop_streak = 0
        end

        @recent_tool_signatures.concat(current)
        @recent_tool_signatures.shift(@recent_tool_signatures.size - LOOP_WINDOW_SIZE) if @recent_tool_signatures.size > LOOP_WINDOW_SIZE

        streak_signal(@unresolved_loop_streak)
      end

      private def streak_signal(streak)
        return nil if streak.zero?

        case streak
        when 1 then :notice
        when 2 then :warning
        when 3 then :critical
        else :break
        end
      end

      # Inject an escalating system message after a repeated turn, prompting the
      # model to converge instead of re-fetching identical results.
      private def inject_tool_loop_warning(level)
        text = TOOL_LOOP_MESSAGES[level]
        return unless text

        Clacky::Logger.warn("agent.tool_loop_detected",
          session_id: @session_id,
          iteration: @iterations,
          level: level.to_s,
          unresolved_streak: @unresolved_loop_streak
        )
        @history.append({ role: "user", content: text, system_injected: true })
      end

      # Force-break the agent loop after sustained, unresolved repetition.
      # Emits a user-visible message so a stuck run does not end silently.
      private def handle_tool_loop_break
        Clacky::Logger.warn("agent.tool_loop_break",
          session_id: @session_id,
          iteration: @iterations,
          unresolved_streak: @unresolved_loop_streak
        )
        @ui&.show_warning("Detected a repeated tool-call loop — stopping to avoid wasting the context window.")
        @history.append({
          role: "user",
          content: "You have repeated the same tool calls #{LOOP_BREAK_LIMIT} times without making " \
                   "progress. Stop calling tools and give your best final answer now based on the " \
                   "results already in the conversation.",
          system_injected: true
        })
      end
    end
  end
end
