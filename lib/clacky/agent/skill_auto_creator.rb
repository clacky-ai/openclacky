# frozen_string_literal: true

module Clacky
  class Agent
    # Scenario 1: Auto-create new skills from complex task patterns.
    #
    # After completing a complex task (high iteration count, no existing skill used),
    # forks a subagent to analyze if the workflow is reusable and worth capturing
    # as a new skill.
    #
    # If the LLM determines it's valuable, it invokes skill-creator in "quick mode"
    # to generate a new skill automatically.
    module SkillAutoCreator
      # Default minimum iterations to consider auto-creating a skill.
      # This counts iterations within the current task only, not session-cumulative.
      DEFAULT_AUTO_CREATE_THRESHOLD = 12

      # Check if we should prompt the LLM to consider creating a new skill
      # Called from SkillEvolution#run_skill_evolution_hooks
      def maybe_create_skill_from_task
        return unless should_auto_create_skill?

        @ui&.show_info("Analyzing task for skill creation opportunity...")

        # Fork an isolated subagent to evaluate + create — does NOT touch main history
        subagent = fork_subagent
        subagent.run(build_skill_creation_prompt)
      end

      # Determine if this task is a candidate for skill auto-creation
      # @return [Boolean]
      private def should_auto_create_skill?
        threshold = skill_evolution_config[:auto_create_threshold] || DEFAULT_AUTO_CREATE_THRESHOLD

        # Calculate iterations within THIS TASK ONLY (not session-cumulative)
        task_iterations = @iterations - @task_start_iterations

        # Conditions (ALL must be true):
        # 1. Current task was complex enough (high iteration count within this task)
        # 2. No skill was explicitly invoked (not a skill refinement session)
        # 3. Task succeeded (not an error state)

        task_iterations >= threshold &&
          !@skill_execution_context &&
          !skill_invoked_in_history?
      end

      # Check if any skill was invoked during this task
      # Looks for invoke_skill tool calls in the conversation history
      # @return [Boolean]
      private def skill_invoked_in_history?
        @history.to_a.any? { |msg|
          msg[:role] == "assistant" &&
            msg[:tool_calls]&.any? { |tc| tc[:name] == "invoke_skill" }
        }
      end

      # Build the skill auto-creation prompt content
      # @return [String]
      private def build_skill_creation_prompt
        <<~PROMPT
          ═══════════════════════════════════════════════════════════════
          SKILL AUTO-CREATION MODE
          ═══════════════════════════════════════════════════════════════
          You just completed a complex task without using any existing skill.

          ## Analysis

          Review the conversation history and determine:
          - Is this workflow likely to be reused in similar future tasks?
          - Does it have a clear input → process → output pattern?
          - Would it save significant time if automated as a skill?

          ## Decision Criteria (ALL must be true)

          1. **Turn is actually finished**: The assistant's last message is
             not a question back to the user, and the user wasn't just asking
             /discussing/exploring (Q&A is not work to capture).
          2. **Reusable**: The workflow could apply to similar tasks in the future
             (not a one-off, project-specific task)
          3. **Well-defined**: Clear steps with consistent logic, not just exploratory conversation
          4. **Valuable**: Would save more than 5 minutes of work if reused
          5. **Generalizable**: Can be parameterized for different inputs/contexts

          ## Action

          If **ALL** criteria are met:
            → Call invoke_skill with:
               - skill_name: "skill-creator"
               - task: A clear description of what to automate and how (be specific)
               - mode: "quick" (enables fast auto-creation without user interviews)
               - suggested_name: A descriptive identifier (lowercase, hyphens OK)

          Example invocation:
          ```
          invoke_skill(
            skill_name: "skill-creator",
            task: "Create a skill to extract and summarize content from URLs. The skill should: 1) fetch the URL content, 2) parse the main text, 3) generate a concise summary. Expected input: URL. Expected output: markdown summary.",
            mode: "quick",
            suggested_name: "url-summarizer"
          )
          ```

          If **NOT all** criteria are met:
            → Respond briefly: "This task doesn't warrant a new skill." (no tool calls)

          ## Constraints

          - Be selective: Don't create skills for one-off tasks or project-specific workflows
          - Be specific: When creating a skill, clearly describe the workflow steps
          - Keep it simple: Focus on the core happy path, edge cases can be added later
          - Prefer generalization: The skill should work across different contexts
        PROMPT
      end
    end
  end
end
