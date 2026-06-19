# frozen_string_literal: true

module Clacky
  class Agent
    # Unified entry point for skill self-evolution system.
    # Coordinates two scenarios:
    #   1. Auto-create new skills from complex task patterns
    #   2. Reflect on executed skills and suggest improvements
    #
    # Triggered at the end of Agent#run (post-run hooks), only for main agents.
    module SkillEvolution
      # Main entry point - runs all skill evolution checks
      # Called from Agent#run after the main loop completes.
      #
      # The two scenarios are mutually exclusive by design:
      #
      #   * If a skill just ran (@skill_execution_context is set), the user's
      #     need was already served by an existing skill. Run Scenario 2
      #     (reflect + possibly improve that skill) and skip Scenario 1 —
      #     otherwise we would auto-extract a near-duplicate "auto-*" skill
      #     from the same task, polluting the skills directory.
      #
      #   * If no skill ran, the task was solved with raw tools. That is the
      #     signal for Scenario 1: if the pattern is complex/repeatable enough,
      #     consider extracting it into a new skill.
      def run_skill_evolution_hooks
        return unless skill_evolution_enabled?
        return if @is_subagent
        return unless skill_evolution_visible? || skill_evolution_has_work?

        with_skill_evolution_phase do
          if @skill_execution_context
            maybe_reflect_on_skill
          else
            maybe_create_skill_from_task
          end
        end
      end

      private def skill_evolution_visible?
        @config.respond_to?(:verbose) && @config.verbose
      end

      private def skill_evolution_has_work?
        if @skill_execution_context
          should_reflect_on_skill?
        else
          should_auto_create_skill?
        end
      end

      private def with_skill_evolution_phase
        return yield unless @ui.respond_to?(:with_phase)

        @ui.with_phase(kind: "skill_evolution", label: "Reflecting on this task") { yield }
      end

      # Check if skill evolution is enabled in config
      # @return [Boolean]
      private def skill_evolution_enabled?
        # Default to true if not explicitly disabled
        return true unless @config.respond_to?(:skill_evolution)

        config = @config.skill_evolution
        return true if config.nil?

        config[:enabled] != false
      end

      # Get skill evolution configuration hash
      # @return [Hash]
      private def skill_evolution_config
        return {} unless @config.respond_to?(:skill_evolution)

        @config.skill_evolution || {}
      end
    end
  end
end
