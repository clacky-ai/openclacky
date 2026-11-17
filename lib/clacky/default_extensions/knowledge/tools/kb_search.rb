# frozen_string_literal: true

require_relative "../lib/knowledge"

module Clacky
  module Tools
    class KbSearch < Base
      self.tool_name = "kb_search"
      self.tool_description = "Search the user's knowledge base (business documents) by keywords. " \
                              "Use when the auto-retrieved passages are missing or insufficient. Returns cited passages with entry ids for kb_read."
      self.tool_parameters = {
        type: "object", properties: {
          query: { type: "string", description: "Keywords or question; try synonyms or names if the first search misses" },
          limit: { type: "integer", description: "Max results (default 5, max 20)" }
        }, required: %w[query]
      }

      def format_call(args)
        "kb_search(#{args[:query] || args["query"]})"
      end

      def format_result(result)
        result.is_a?(Hash) && result[:count] ? "#{result[:count]} hits" : super
      end

      def execute(query:, limit: 5, **)
        unless Clacky::Knowledge.enabled?
          return { error: "Knowledge base is empty or turned off. Add .md files to #{Clacky::Knowledge.store.entries_dir}" }
        end

        hits = Clacky::Knowledge.index.search(query, limit: limit.to_i.clamp(1, 20))
        return { count: 0, results: "No matching passages. Try other keywords; do not invent an answer." } if hits.empty?

        { count: hits.size, results: Clacky::Knowledge.format_hits(hits) }
      end
    end
  end
end
