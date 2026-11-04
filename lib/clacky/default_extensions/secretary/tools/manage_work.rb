# frozen_string_literal: true
module Clacky
  module Tools
    class ManageWork < Base
      self.tool_name = "manage_work"
      self.tool_description = "List/get your work; update requirements, relay a reply/decision, pause or cancel. Use expected_revision when editing a previously read card."
      self.tool_parameters = {
        type: "object", properties: {
          action: { type: "string", enum: %w[list get update reply pause cancel] },
          work_id: { type: "string" }, instruction: { type: "string" },
          expected_revision: { type: "integer" }
        }, required: %w[action]
      }
      def execute(action:, work_id: nil, instruction: nil, expected_revision: nil, **)
        raise "Work management requires the OpenClacky web server" unless agent&.work_service
        agent.work_service.manage(agent.session_id, action: action, work_id: work_id,
                                 instruction: instruction, expected_revision: expected_revision)
      end
    end
  end
end
