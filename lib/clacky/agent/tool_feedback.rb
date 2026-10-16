# frozen_string_literal: true

module Clacky
  class Agent
    # A script may attach a structured request to its executing tool. The request
    # is consumed with that tool's result, never scheduled for a later turn.
    module ToolFeedback
      def attach_tool_feedback(tool_call_id:, request:)
        normalized = normalize_tool_feedback(request, tool_call_id)
        @tool_feedback_mutex.synchronize do
          active = @active_feedback_tool
          return :stale unless active && active[:id] == tool_call_id && active[:task_id] == @current_task_id && !@cancel_flag&.cancelled?
          return active[:request] == normalized ? :duplicate : :conflict if active[:request]

          active[:request] = normalized
          :accepted
        end
      end

      private def execute_with_tool_feedback(call)
        active = { id: call[:id], task_id: @current_task_id }
        @tool_feedback_mutex.synchronize { @active_feedback_tool = active }
        result = yield
        request = @tool_feedback_mutex.synchronize do
          @active_feedback_tool = nil if @active_feedback_tool.equal?(active)
          active[:request]
        end
        return result unless request
        raise ArgumentError, "feedback requires a successful tool result" unless result.is_a?(Hash) && !result[:error] && result[:success] != false && (call[:name] != "terminal" || result[:exit_code] == 0)
        raise ArgumentError, "tool returned two feedback requests" if result[:feedback_request]

        result.merge(feedback_request: request)
      ensure
        @tool_feedback_mutex.synchronize { @active_feedback_tool = nil if @active_feedback_tool.equal?(active) }
      end

      private def normalize_tool_feedback(request, id)
        raise ArgumentError, "feedback request must be an object" unless request.is_a?(Hash)
        encoded = JSON.generate(request)
        raise ArgumentError, "feedback request exceeds 32 KiB" if encoded.bytesize > 32 * 1024
        data = JSON.parse(encoded, symbolize_names: true)
        questions = Tools::AskUser.normalize_questions(data)
        raise ArgumentError, "feedback requires a question" if questions.empty?

        data.merge(id: id, questions: questions)
      end
    end
  end
end
