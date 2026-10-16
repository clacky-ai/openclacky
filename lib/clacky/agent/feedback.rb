# frozen_string_literal: true

module Clacky
  class Agent
    module Feedback
      # Extensions prepare a single immutable snapshot before the UI or its
      # countdown sees it. The same snapshot becomes the model's tool result.
      private def prepare_feedback_request(call, result)
        args = call[:arguments].is_a?(String) ? JSON.parse(call[:arguments]) : call[:arguments]
        request = {
          request_id: call[:id].to_s,
          questions: Tools::AskUser.normalize_questions(args),
          context: Tools::AskUser.fetch_key(args, :context).to_s
        }
        @hooks.trigger(:prepare_feedback, request)
        check_stale!
        request[:request_id] = call[:id].to_s
        request[:questions] = Tools::AskUser.normalize_questions(request)
        raise ArgumentError, "Feedback preparation removed all questions" if request[:questions].empty?

        request[:context] = request[:context].to_s
        @history.attach_feedback_request(call[:id], request)
        result[:message] = Tools::AskUser.render_text(request[:questions], request[:context])
        request
      end
    end
  end
end
