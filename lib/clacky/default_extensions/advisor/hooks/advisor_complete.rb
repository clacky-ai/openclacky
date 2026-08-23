# frozen_string_literal: true

require_relative "advisor"

# on_complete: a run has ended — reset the per-run analysis budget so the
# next run starts fresh.
Clacky::ExtensionHookRegistry.add do |_result, agent|
  next unless Clacky::Advisor.enabled_for?(agent)

  Clacky::Advisor.worker_for(agent).finish_run
end
