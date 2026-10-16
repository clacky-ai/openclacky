# frozen_string_literal: true

module Clacky
  class Agent
    # Business tools describe choices without owning the task's wait loop.
    module ToolFeedback
      def tool_feedback_requests?
        true
      end

      private def stage_tool_feedback(result)
        return unless result.is_a?(Hash)
        request = result.delete(:feedback_request)
        return unless request.is_a?(Hash) && !Tools::AskUser.normalize_questions(request).empty?
        @pending_tool_feedback_request = request
      end

      # Wait only after the model has finished validation and its closing reply.
      private def settle_tool_feedback
        request = @pending_tool_feedback_request
        return unless request
        @pending_tool_feedback_request = nil
        check_stale!
        questions = Tools::AskUser.normalize_questions(request)
        first = questions.first
        context = Tools::AskUser.fetch_key(request, :context).to_s
        @history.append_ext_event(type: "ext.clacky.feedback.requested", data: { request: request })
        @ui&.show_feedback_request(first[:question], context, first[:options], questions: questions)
        return :waiting unless @config.permission_mode == :auto_approve

        outcome = @ui ? @ui.request_feedback_with_countdown(seconds: @config.ask_user_timeout_seconds) : :timeout
        check_stale!
        @history.append_ext_event(type: "ext.clacky.feedback.resolved",
                                  data: { context: context, resolution: outcome.is_a?(String) ? :answered : outcome })
        instruction = if outcome == :timeout && @config.permission_mode == :auto_approve
                        Tools::AskUser.fetch_key(request, :auto_reply) ||
                          "No user answered. Make a reasonable decision for this feedback request and continue."
                      elsif outcome.is_a?(String) && !outcome.strip.empty?
                        "The user answered this feedback request: #{outcome}"
                      end
        return :waiting unless instruction

        @history.append(role: "user", content: instruction, system_injected: true)
        :continue
      end
    end
  end
end
