# frozen_string_literal: true
module Clacky
  module Tools
    class DelegateWork < Base
      self.tool_name = "delegate_work"
      self.tool_description = "Start independent read/research work and return its ID immediately. The host includes verbatim user context. No sending, booking, payment or shell access."
      self.tool_parameters = {
        type: "object", properties: {
          title: { type: "string", description: "Short work title" },
          task: { type: "string", description: "Objective, necessary background and completion criteria" },
          constraints: { type: "string", description: "Confirmed constraints, permissions and unknowns" }
        }, required: %w[title task]
      }
      def execute(title:, task:, constraints: "", **)
        raise "Delegation requires the OpenClacky web server" unless agent&.work_service
        agent.work_service.delegate(agent, title: title, task: task, constraints: constraints)
      end
    end
  end
end
