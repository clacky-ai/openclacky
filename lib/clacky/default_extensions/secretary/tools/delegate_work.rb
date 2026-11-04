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
      def format_call(args)
        Clacky::I18n.t("work.delegating", title: args[:title] || args["title"])
      end

      def format_result(result)
        return super unless result.is_a?(Hash) && (result[:id] || result["id"])
        Clacky::I18n.translate(result[:locale] || result["locale"] || Clacky::I18n.locale,
                               "work.delegated", title: result[:title] || result["title"])
      end

      # Reuse the same tool-result presentation as worker reports. Replay can
      # reconstruct this from old persisted cards without rewriting history.
      def ui_result(result)
        return nil unless result.is_a?(Hash) && (result[:id] || result["id"]) && (result[:session_id] || result["session_id"])
        { type: "markdown", content: format_result(result) }
      end

      def execute(title:, task:, constraints: "", **)
        raise "Delegation requires the OpenClacky web server" unless agent&.work_service
        agent.work_service.delegate(agent, title: title, task: task, constraints: constraints)
      end
    end
  end
end
