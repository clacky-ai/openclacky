# frozen_string_literal: true
module Clacky
  module Tools
    class ManageWork < Base
      self.tool_name = "manage_work"
      self.tool_description = "List/get your work; update requirements, relay a reply/decision, pause, cancel, or resume paused/failed work in its existing session. For continuing interrupted work, use resume with its work_id rather than creating a new delegation. Use expected_revision when editing a previously read card."
      self.tool_parameters = {
        type: "object", properties: {
          action: { type: "string", enum: %w[list get update reply pause cancel resume] },
          work_id: { type: "string" }, instruction: { type: "string" },
          expected_revision: { type: "integer" }
        }, required: %w[action]
      }
      def execute(action:, work_id: nil, instruction: nil, expected_revision: nil, **)
        raise "Work management requires the OpenClacky web server" unless agent&.work_service
        result = agent.work_service.manage(agent.session_id, action: action, work_id: work_id,
                                 instruction: instruction, expected_revision: expected_revision)
        %w[reply update resume].include?(action) ? result.merge(notify_user: false) : result
      end
    end
  end
end
