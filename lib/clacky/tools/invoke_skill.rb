# frozen_string_literal: true

module Clacky
  module Tools
    # Tool for invoking skills within the agent
    # This allows the AI to call skills as tools rather than requiring explicit user commands
    class InvokeSkill < Base
      self.tool_name = "invoke_skill"
      self.tool_description = "Invoke a specialized skill to handle specific tasks. Use this when user's request matches a skill's description (e.g., code exploration, document creation, etc.). This will read the skill's instructions and execute them appropriately (either inline or in a subagent)."
      self.tool_category = "skill_management"
      self.tool_parameters = {
        type: "object",
        properties: {
          skill_name: {
            type: "string",
            description: "Name of the skill to invoke (e.g., 'code-explorer', 'pptx', 'pdf')"
          },
          task: {
            type: "string",
            description: "The task or query to pass to the skill"
          }
        },
        required: ["skill_name", "task"]
      }

      # Execute the skill invocation
      # @param skill_name [String] Name of the skill to invoke
      # @param task [String] Task description to pass to the skill
      # @param agent [Clacky::Agent] Agent instance (injected)
      # @param skill_loader [Clacky::SkillLoader] Skill loader instance (injected)
      # @return [Hash] Result of skill execution
      def execute(skill_name:, task:, agent: nil, skill_loader: nil, working_dir: nil)
        # Validate injected dependencies
        return { error: "Agent context is required" } unless agent
        return { error: "Skill loader is required" } unless skill_loader

        # Find skill by name
        skill = skill_loader.find_by_name(skill_name)
        return { error: "Skill not found: #{skill_name}" } unless skill

        # Execute skill based on its configuration.
        # Note: disable-model-invocation only prevents the skill from appearing in AVAILABLE SKILLS
        # (so the model won't auto-discover it). It does NOT block execution here — the user may
        # have triggered this skill explicitly via a slash command (/skill-name).
        if skill.fork_agent?
          # Execute in isolated subagent
          result = agent.send(:execute_skill_with_subagent, skill, task)
          {
            message: "Skill '#{skill_name}' executed in subagent",
            result: result,
            skill_type: "subagent"
          }
        else
          # Deferred injection path: enqueue the skill inject on the agent.
          #
          # Injecting inside execute() would produce an illegal message ordering for Bedrock:
          #   assistant: {toolUse: invoke_skill}
          #   assistant: {text: skill_instructions}   ← injected here (breaks pairing)
          #   user:      {toolResult: invoke_skill}   ← observe() appends this too late
          #
          # Instead, enqueue the injection so the agent loop can flush it AFTER observe()
          # appends the toolResult, producing the correct sequence:
          #   assistant: {toolUse: invoke_skill}
          #   user:      {toolResult: ...}            ← observe() appends first
          #   assistant: {text: skill_instructions}   ← flush_pending_injections runs here
          #   user:      "[SYSTEM] please proceed"
          agent.enqueue_injection(skill, task)
          "Skill '#{skill_name}' instructions expanded. Proceed to execute the task."
        end
      end

      # Format the tool call for display
      # @param args [Hash] Tool arguments
      # @return [String] Formatted call description
      def format_call(args)
        skill = args[:skill_name] || args["skill_name"]
        "InvokeSkill(#{skill})"
      end

      # Format the tool result for display
      # @param result [Hash] Tool execution result
      # @return [String] Formatted result summary
      def format_result(result)
        if result.is_a?(String)
          result
        elsif result[:error]
          "Error: #{result[:error]}"
        elsif result[:skill_type] == "subagent"
          "Subagent executed successfully"
        else
          "Skill content expanded"
        end
      end
    end
  end
end
