# frozen_string_literal: true

require "json"

module Clacky
  # Drives the /goal Ralph-style loop for a single session.
  #
  # Responsibilities:
  #   - own the GoalState lifecycle (set / pause / resume / clear)
  #   - after each agent turn, ask a lightweight judge whether the goal is
  #     done, then decide whether to feed the loop another turn
  #   - enforce the turn budget and auto-pause on repeated judge failures
  #
  # The judge is a single stateless LLM call routed through the same Client
  # the agent already holds (optionally on a cheaper model name). It never
  # touches conversation history — it only sees the goal text and the agent's
  # last response.
  class GoalManager
    # After this many consecutive judge-output parse failures the loop
    # auto-pauses instead of burning the whole turn budget on a judge model
    # that cannot follow the JSON reply contract.
    MAX_CONSECUTIVE_JUDGE_FAILURES = 3

    JUDGE_MAX_TOKENS = 512

    JUDGE_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a strict judge deciding whether an autonomous agent has achieved a user's stated goal.
      You receive the goal text and the agent's most recent response.

      Decide one verdict:
      - "done": the goal is fully satisfied, OR the agent clearly explains the goal is
        unachievable / blocked / needs user input (treat a genuine block as done).
      - "continue": not done, and there is a concrete next step the agent can take now.
        This is the default when in doubt.

      Reply with ONLY a single-line JSON object, no prose, no code fences:
      {"verdict": "done", "reason": "<one short sentence>"}
      {"verdict": "continue", "reason": "<one short sentence>"}
    PROMPT

    CONTINUATION_PROMPT_TEMPLATE = <<~PROMPT.freeze
      [Continuing toward your standing goal]
      Goal: %<goal>s

      Continue working toward this goal. Take the next concrete step.
      If you believe the goal is complete, state so explicitly and stop.
      If you are blocked and need input from the user, say so clearly and stop.
    PROMPT

    attr_reader :state

    def initialize(judge_client:, judge_model:, state: nil)
      @judge_client = judge_client
      @judge_model = judge_model
      @state = state
      @consecutive_judge_failures = 0
    end

    def active?
      @state&.active? || false
    end

    def has_goal?
      @state && (@state.active? || @state.paused?)
    end

    # --- lifecycle ----------------------------------------------------------

    def set(goal, max_turns: nil)
      goal = goal.to_s.strip
      raise ArgumentError, "goal text is empty" if goal.empty?

      @state = GoalState.new(
        goal: goal,
        max_turns: max_turns || GoalState::DEFAULT_MAX_TURNS
      )
      @consecutive_judge_failures = 0
      @state
    end

    def pause(reason: "user-paused")
      return nil unless @state
      @state.status = "paused"
      @state.paused_reason = reason
      @state
    end

    def resume(reset_budget: true)
      return nil unless @state
      @state.status = "active"
      @state.paused_reason = nil
      @state.turns_used = 0 if reset_budget
      @consecutive_judge_failures = 0
      @state
    end

    def clear
      @state = nil
    end

    # Human-readable one-liner for /goal status and status bars.
    def status_line
      return "No active goal. Set one with /goal <text>." unless @state

      s = @state
      meta = "#{s.turns_used}/#{s.max_turns} turns"
      case s.status
      when "active"
        "⊙ Goal (active, #{meta}): #{s.goal}"
      when "paused"
        extra = s.paused_reason ? " — #{s.paused_reason}" : ""
        "⏸ Goal (paused, #{meta}#{extra}): #{s.goal}"
      when "done"
        "✓ Goal done (#{meta}): #{s.goal}"
      else
        "Goal (#{s.status}, #{meta}): #{s.goal}"
      end
    end

    # --- the main hook, called after every agent turn ----------------------

    # Judge the finished turn and decide the loop's next move.
    #
    # @param last_response [String] the agent's final assistant text this turn
    # @return [Hash] decision:
    #   {
    #     should_continue: Boolean,          # caller should run another turn
    #     continuation_prompt: String|nil,   # prompt to feed the next turn
    #     status: String,                    # goal status after this turn
    #     verdict: "done"|"continue",
    #     reason: String,
    #     message: String                    # user-visible one-liner
    #   }
    def evaluate_after_turn(last_response)
      return inactive_decision unless @state&.active?

      @state.turns_used += 1
      @state.last_turn_at = Time.now.to_f

      last_response = last_response.to_s
      if last_response.strip.empty?
        # Nothing to judge — treat as a transient blip, keep going if budget allows.
        return continue_or_pause("empty response (nothing to evaluate)")
      end

      verdict, reason = judge(@state.goal, last_response)
      @state.last_verdict = verdict
      @state.last_reason = reason

      if verdict.nil?
        @consecutive_judge_failures += 1
        if @consecutive_judge_failures >= MAX_CONSECUTIVE_JUDGE_FAILURES
          return pause_decision(
            "judge returned unusable output #{@consecutive_judge_failures} turns in a row"
          )
        end
        return continue_or_pause("judge output unusable — continuing")
      end

      @consecutive_judge_failures = 0

      if verdict == "done"
        @state.status = "done"
        return {
          should_continue: false,
          continuation_prompt: nil,
          status: "done",
          verdict: "done",
          reason: reason,
          message: "✓ Goal achieved: #{reason}"
        }
      end

      continue_or_pause(reason)
    end

    # --- persistence bridge -------------------------------------------------

    def to_h
      @state&.to_h
    end

    private def continue_or_pause(reason)
      if @state.budget_exhausted?
        return pause_decision(
          "turn budget exhausted (#{@state.turns_used}/#{@state.max_turns})"
        )
      end

      {
        should_continue: true,
        continuation_prompt: continuation_prompt,
        status: "active",
        verdict: "continue",
        reason: reason,
        message: "↻ Continuing toward goal (#{@state.turns_used}/#{@state.max_turns}): #{reason}"
      }
    end

    private def pause_decision(reason)
      @state.status = "paused"
      @state.paused_reason = reason
      {
        should_continue: false,
        continuation_prompt: nil,
        status: "paused",
        verdict: @state.last_verdict || "continue",
        reason: reason,
        message: "⏸ Goal paused — #{reason}. Use /goal resume to continue, or /goal clear to stop."
      }
    end

    private def inactive_decision
      {
        should_continue: false,
        continuation_prompt: nil,
        status: @state&.status,
        verdict: "inactive",
        reason: "no active goal",
        message: ""
      }
    end

    def continuation_prompt
      format(CONTINUATION_PROMPT_TEMPLATE, goal: @state.goal)
    end

    # Run the judge LLM call. Fail-open: any error returns [nil, reason] so the
    # caller counts it as a parse failure (and eventually auto-pauses) rather
    # than crashing the agent loop.
    #
    # @return [Array(String|nil, String)] [verdict, reason]; verdict nil on failure
    private def judge(goal, last_response)
      messages = [
        { role: "system", content: JUDGE_SYSTEM_PROMPT },
        { role: "user", content: judge_user_prompt(goal, last_response) }
      ]

      raw = @judge_client.send_messages(messages, model: @judge_model, max_tokens: JUDGE_MAX_TOKENS)
      parse_judge_response(raw)
    rescue StandardError => e
      Clacky::Logger.info("goal.judge_failed", error: e.message) if defined?(Clacky::Logger)
      [nil, "judge error: #{e.class}"]
    end

    private def judge_user_prompt(goal, last_response)
      <<~PROMPT
        Goal:
        #{truncate(goal, 2000)}

        Agent's most recent response:
        #{truncate(last_response, 4000)}

        Is the goal satisfied — done or continue?
      PROMPT
    end

    # Parse the judge reply into [verdict, reason]. Fail-open: unparseable
    # output returns [nil, reason].
    private def parse_judge_response(raw)
      text = raw.to_s.strip
      return [nil, "judge returned empty response"] if text.empty?

      # Strip markdown code fences the model may wrap JSON in.
      if text.start_with?("```")
        text = text.gsub(/\A```[a-zA-Z]*\n?/, "").gsub(/```\z/, "").strip
      end

      json = extract_json_object(text)
      return [nil, "judge reply was not JSON"] unless json

      reason = json["reason"].to_s.strip
      reason = "no reason provided" if reason.empty?

      verdict = json["verdict"].to_s.strip.downcase
      verdict = "done" if verdict.empty? && json.key?("done") && truthy?(json["done"])
      verdict = "continue" unless %w[done continue].include?(verdict)

      [verdict, reason]
    end

    private def extract_json_object(text)
      JSON.parse(text)
    rescue JSON::ParserError
      match = text.match(/\{.*\}/m)
      return nil unless match
      begin
        JSON.parse(match[0])
      rescue JSON::ParserError
        nil
      end
    end

    private def truthy?(value)
      return value if value == true || value == false
      %w[true yes 1 done].include?(value.to_s.strip.downcase)
    end

    private def truncate(text, limit)
      str = text.to_s
      return str if str.length <= limit
      "#{str[0, limit]}…"
    end
  end
end
