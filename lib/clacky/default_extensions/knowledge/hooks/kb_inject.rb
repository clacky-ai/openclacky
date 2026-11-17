# frozen_string_literal: true

require_relative "../lib/knowledge"

# on_start: search the knowledge base with the user's question and append the
# top hits as a system-injected message, so every user-facing turn (web or
# channel) is grounded without relying on the model to call kb_search.
# Never blocks the turn: any failure is logged and the run continues.

# Loaded once at process start: create entries/ so there is an obvious place
# to drop documents — no kb.yml needed.
Clacky::Knowledge.store.ensure_dirs!

Clacky::ExtensionHookRegistry.add do |user_input, agent, context|
  begin
    question = user_input.to_s.strip
    next if question.empty?
    next unless Clacky::Knowledge.inject_for?(agent)
    next unless Clacky::Knowledge.enabled?

    hits = Clacky::Knowledge.index.search(question, limit: Clacky::Knowledge.top_k)
    next if hits.empty?

    agent.history.append(
      role: "user",
      content: Clacky::Knowledge.reminder(hits),
      system_injected: true,
      knowledge_recall: true,
      task_id: context&.dig(:run_id).to_i
    )
  rescue StandardError => e
    Clacky::Logger.warn("knowledge.inject_failed", error: e)
  end
  nil
end
