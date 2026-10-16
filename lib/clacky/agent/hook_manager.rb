# frozen_string_literal: true

module Clacky
  class HookManager
    HOOK_EVENTS = [
      :before_tool_use,
      :after_tool_use,
      :prepare_feedback,
      :on_tool_error,
      :on_start,
      :on_complete,
      :on_iteration,
      :session_rollback
    ].freeze

    attr_accessor :agent

    def initialize(agent: nil)
      @hooks = Hash.new { |h, k| h[k] = [] }
      @agent = agent
    end

    def add(event, &block)
      validate_event!(event)
      @hooks[event] << block
    end

    # @return [Hash] `{action: :allow}`, `{action: :deny, reason:}`, or
    #   `{action: :handled, result:}` when a hook fulfilled the event itself.
    # on_start receives (user_input, agent, context) after task/history initialization.
    # Its handled result is returned unchanged from Agent#run; the extension
    # supplies the run-result status and any queue/feedback flags it needs.
    # on_start is not fired for steering input inside an already running turn.
    # The agent follows the event payload, so ext hooks can
    # call `agent.emit_event(...)`. Blocks are procs — those declaring fewer
    # params (`|call|`, `|call, result|`) silently ignore extra arguments.
    # Start/complete append context after the agent. Completion is observation-only.
    # prepare_feedback receives (request, agent) after tool tracking, before UI
    # display/countdown. It may extend questions, display context and model-only
    # answer_context in place; answer_context is never sent to UI subscribers.
    # return values are ignored. Keep work bounded; no separate UI events.
    def trigger(event, *args)
      validate_event!(event)
      # Keep payload hashes positional: Ruby 2.6 otherwise promotes their keys
      # into keyword arguments, breaking existing tool hooks.
      context = args.pop if [:on_start, :on_complete].include?(event) && args.length == 2
      result = { action: :allow }

      @hooks[event].each do |hook|
        begin
          callback_args = [*args, @agent]
          callback_args << context.dup if context
          hook_result = hook.call(*callback_args)
          next if [:on_complete, :prepare_feedback].include?(event)
          next unless hook_result.is_a?(Hash)
          # First deny wins and stops the chain: a weaker later verdict must
          # never clobber a stronger earlier one, and the first deny's reason
          # is the one that reaches the agent. Rewrite hooks mutate `call` in
          # place (chained rewrite), so for non-deny results there's nothing to
          # merge — we just keep going.
          #
          # :handled short-circuits the same way: the hook has already fulfilled
          # the event, so later hooks have nothing left to act on.
          if hook_result[:action] == :deny || hook_result[:action] == :handled
            result = hook_result
            break
          end
        rescue StandardError => e
          # Log error but don't fail
          Clacky::Logger.error("Hook error", event: event, error: e)
        end
      end

      result
    end

    def has_hooks?(event)
      @hooks[event].any?
    end

    def clear(event = nil)
      if event
        validate_event!(event)
        @hooks[event].clear
      else
        @hooks.clear
      end
    end


    def validate_event!(event)
      return if HOOK_EVENTS.include?(event)

      raise ArgumentError, "Invalid hook event: #{event}. Must be one of #{HOOK_EVENTS.join(', ')}"
    end
  end
end
