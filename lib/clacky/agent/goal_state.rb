# frozen_string_literal: true

module Clacky
  # Serializable per-session goal state for the /goal Ralph-style loop.
  #
  # A "goal" is a standing objective the agent works toward across multiple
  # turns without the user re-prompting each time. After every turn a judge
  # decides done/continue; while continuing (and under the turn budget) the
  # loop feeds itself a continuation prompt and runs another turn.
  class GoalState
    DEFAULT_MAX_TURNS = 20

    # active   — loop is running, judge fires after each turn
    # paused   — stopped but recoverable via /goal resume (budget exhausted,
    #            user pause, or repeated judge failures)
    # done     — judge decided the goal is satisfied
    STATUSES = %w[active paused done].freeze

    attr_accessor :goal, :status, :turns_used, :max_turns,
                  :last_verdict, :last_reason, :paused_reason,
                  :created_at, :last_turn_at

    def initialize(goal:, max_turns: DEFAULT_MAX_TURNS, status: "active",
                   turns_used: 0, last_verdict: nil, last_reason: nil,
                   paused_reason: nil, created_at: nil, last_turn_at: nil)
      @goal = goal.to_s
      @status = STATUSES.include?(status.to_s) ? status.to_s : "active"
      @turns_used = turns_used.to_i
      @max_turns = max_turns.to_i.positive? ? max_turns.to_i : DEFAULT_MAX_TURNS
      @last_verdict = last_verdict
      @last_reason = last_reason
      @paused_reason = paused_reason
      @created_at = created_at || Time.now.to_f
      @last_turn_at = last_turn_at
    end

    def active?
      @status == "active"
    end

    def paused?
      @status == "paused"
    end

    def done?
      @status == "done"
    end

    def budget_exhausted?
      @turns_used >= @max_turns
    end

    def to_h
      {
        goal: @goal,
        status: @status,
        turns_used: @turns_used,
        max_turns: @max_turns,
        last_verdict: @last_verdict,
        last_reason: @last_reason,
        paused_reason: @paused_reason,
        created_at: @created_at,
        last_turn_at: @last_turn_at
      }
    end

    def self.from_h(data)
      return nil unless data.is_a?(Hash)

      # Tolerate both symbol and string keys (session.json round-trips as strings).
      get = ->(key) { data[key] || data[key.to_s] }
      goal = get.call(:goal).to_s
      return nil if goal.strip.empty?

      new(
        goal: goal,
        status: get.call(:status) || "active",
        turns_used: get.call(:turns_used),
        max_turns: get.call(:max_turns),
        last_verdict: get.call(:last_verdict),
        last_reason: get.call(:last_reason),
        paused_reason: get.call(:paused_reason),
        created_at: get.call(:created_at),
        last_turn_at: get.call(:last_turn_at)
      )
    end
  end
end
