# frozen_string_literal: true

module Clacky
  class Agent
    # Scenario 2: Reflect on skill execution and suggest improvements.
    #
    # After a skill completes, forks a subagent to analyze:
    #   - Were instructions clear enough?
    #   - Any missing edge cases?
    #   - Any improvements needed?
    #
    # If the LLM identifies concrete improvements, it invokes skill-creator
    # to update the skill.
    module SkillReflector
      # Minimum iterations for a skill execution to warrant reflection.
      # This counts iterations within the skill execution only, not session-cumulative.
      MIN_SKILL_ITERATIONS = 5

      # Check if we should reflect on the skill that just executed
      # Called from SkillEvolution#run_skill_evolution_hooks
      def maybe_reflect_on_skill
        return unless should_reflect_on_skill?

        skill_name = @skill_execution_context[:skill_name]

        @ui&.show_info("Reflecting on skill execution: #{skill_name}")
        subagent = fork_subagent
        result = subagent.run(build_skill_reflection_prompt(skill_name))

        if result
          subagent_cost = result[:total_cost_usd] || 0.0
          @total_cost += subagent_cost
          @ui&.update_sessionbar(cost: @total_cost, cost_source: @cost_source)
        end

        @skill_execution_context = nil
      end

      private def should_reflect_on_skill?
        return false unless @skill_execution_context
        return false unless @skill_execution_context[:slash_command]

        source = @skill_execution_context[:source]
        return false if source == :default || source == :brand

        start_iteration = @skill_execution_context[:start_iteration]
        iterations = @iterations - start_iteration
        iterations >= MIN_SKILL_ITERATIONS
      end

      # Build the reflection prompt content
      # @param skill_name [String]
      # @return [String]
      private def build_skill_reflection_prompt(skill_name)
        <<~PROMPT
          ═══════════════════════════════════════════════════════════════
          SKILL REFLECTION MODE
          ═══════════════════════════════════════════════════════════════
          You just executed the skill "#{skill_name}".

          ## Quick Analysis

          Reflect on whether the skill could be improved:
          - Were the instructions clear enough?
          - Did you encounter any edge cases not covered?
          - Were there any steps that could be streamlined?
          - Is there missing context that would make it easier next time?
          - Did the skill produce the expected results?

          ## Decision

          If the assistant's last message is a question back to the user
          (the turn isn't actually finished), or the user was just asking/
          discussing rather than finishing a task:
            → Respond briefly: "Skill #{skill_name} worked well, no improvements needed."

          If you identified **concrete, actionable improvements**:
            → Call invoke_skill("skill-creator", task: "Improve skill #{skill_name}: [describe specific improvements needed]")

          If the skill worked well as-is:
            → Respond briefly: "Skill #{skill_name} worked well, no improvements needed."

          ## Constraints

          - DO NOT spend more than 30 seconds on this reflection
          - Be specific and actionable in your improvement suggestions
          - Only suggest improvements that would make a meaningful difference
          - If you're unsure, err on the side of "no improvements needed"
        PROMPT
      end
    end
  end
end
