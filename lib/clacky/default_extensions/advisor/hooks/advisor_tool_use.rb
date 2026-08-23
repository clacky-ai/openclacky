# frozen_string_literal: true

require_relative "advisor"

# after_tool_use: record the tool trail and detect the wrap-up signal.
# Runs on the main agent thread, but only does O(1) bookkeeping — the LLM
# analysis is dispatched to a detached thread inside the worker.
Clacky::ExtensionHookRegistry.add do |call, result, agent|
  next unless Clacky::Advisor.enabled_for?(agent)

  Clacky::Advisor.worker_for(agent).observe_tool(call, result)
end
