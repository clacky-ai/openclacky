# frozen_string_literal: true
module Clacky
  module Tools
    class YieldWork < Base
      self.tool_name = "yield_work"
      self.tool_description = "End this execution: complete with evidence, request a user decision, or wait. Channel matching requires genuine channel/chat/sent-message IDs; otherwise accept a relayed reply in the panel."
      self.tool_parameters = {
        type: "object", properties: {
          reason: { type: "string", enum: %w[waiting_reply needs_user completed] },
          summary: { type: "string", description: "Result with evidence, concrete question, or what you are waiting for" },
          check_at: { type: "string", description: "Optional future ISO8601 timestamp including timezone" },
          channel: { type: "string" }, conversation_id: { type: "string" }, reply_to: { type: "string" }
        }, required: %w[reason summary]
      }
      def execute(reason:, summary:, check_at: nil, channel: nil, conversation_id: nil, reply_to: nil, **)
        raise "Yield requires a delegated server work session" unless agent&.work_service
        agent.work_service.yield_work(agent, reason: reason, summary: summary, check_at: check_at,
                                     channel: channel, conversation_id: conversation_id, reply_to: reply_to)
      end
    end
  end
end
