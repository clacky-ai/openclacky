# frozen_string_literal: true
module Clacky
  module Tools
    class YieldWork < Base
      self.tool_name = "yield_work"
      self.tool_description = "End this execution: complete with evidence, request a user decision, or wait. Channel matching requires genuine channel/chat/sent-message IDs; otherwise accept a relayed reply in the panel."
      self.tool_parameters = {
        type: "object", properties: {
          reason: { type: "string", enum: %w[waiting_event needs_input completed], description: "needs_input asks the main agent for help or a decision; waiting_event awaits an external reply or timed checkpoint" },
          summary: { type: "string", description: "Result with evidence, concrete question, or what you are waiting for" },
          display_summary: { type: "string", description: "User-facing progress in one short sentence (max 100 characters): result, question or what is awaited. No internal IDs, channel metadata or execution narration." },
          check_at: { type: "string", description: "Optional future ISO8601 timestamp including timezone" },
          channel: { type: "string" }, conversation_id: { type: "string" }, reply_to: { type: "string" }
        }, required: %w[reason summary]
      }
      def format_call(args)
        concise = (args[:display_summary] || args["display_summary"]).to_s.strip
        return concise if !concise.empty? && concise.length <= 100
        "yield_work(#{args[:reason] || args['reason']})"
      end

      # Both live rendering and history replay use the host's tool UI contract.
      def ui_result(result)
        return nil unless result[:work_yielded] && !result[:message].to_s.empty?
        { type: "markdown", content: result[:message] }
      end

      def execute(reason:, summary:, display_summary: nil, check_at: nil, channel: nil, conversation_id: nil, reply_to: nil, **)
        raise "Yield requires a delegated server work session" unless agent&.work_service
        agent.work_service.yield_work(agent, reason: reason, summary: summary, display_summary: display_summary, check_at: check_at,
                                     channel: channel, conversation_id: conversation_id, reply_to: reply_to)
      end
    end
  end
end
