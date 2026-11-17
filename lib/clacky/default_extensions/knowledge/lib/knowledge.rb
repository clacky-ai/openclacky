# frozen_string_literal: true

require_relative "store"
require_relative "index"

module Clacky
  # Shared entry point for the knowledge extension's hook and tools.
  module Knowledge
    DEFAULT_ROOT = "~/.clacky/knowledge"
    DEFAULT_TOP_K = 5
    SNIPPET_CHARS = 400
    @mutex = Mutex.new

    class << self
      attr_writer :root

      def root
        @root || ENV["CLACKY_KNOWLEDGE_DIR"] || DEFAULT_ROOT
      end

      def store
        Store.new(root)
      end

      def enabled?
        store.enabled?
      end

      # Index cached per root; rebuilt when kb.yml or any entry changes.
      def index
        s = store
        sig = s.signature
        @mutex.synchronize do
          unless @cache && @cache[:root] == s.root && @cache[:sig] == sig
            @cache = { root: s.root, sig: sig, index: Index.new(s.entries) }
          end
          @cache[:index]
        end
      end

      def top_k
        k = store.config["inject_top_k"].to_i
        k > 0 ? k : DEFAULT_TOP_K
      end

      AGENT_ID = "knowledge"

      # Only the knowledge agent recalls automatically; subagents never do.
      # Making it the default agent in Settings › General is how it covers
      # every new and channel session.
      def inject_for?(agent)
        return false if agent.instance_variable_get(:@is_subagent)
        profile = agent.respond_to?(:agent_profile) && agent.agent_profile
        !!profile && profile.name == AGENT_ID
      end

      # "[K1] title · folder: 书/章 · source: … (id: …)\nsnippet"
      def format_hits(hits)
        hits.each_with_index.map do |h, i|
          e = h.entry
          head = ["[K#{i + 1}] #{e.title}", (e.folder.to_s.empty? ? nil : "folder: #{e.folder}"), e.source && "source: #{e.source}"].compact.join(" · ")
          "#{head} (id: #{e.id})\n#{snippet(h.text)}"
        end.join("\n\n")
      end

      def snippet(text)
        text.length > SNIPPET_CHARS ? "#{text[0, SNIPPET_CHARS]}…" : text
      end

      def reminder(hits)
        <<~MD.strip
          <knowledge_base>
          Passages auto-retrieved from the user's knowledge base for this question (may be partial or irrelevant).
          Ground your answer in them; the [K1] labels are for your reference only — never write them in the reply. If they are not enough, call kb_search with other keywords or kb_read for the full document.
          Do not invent facts the knowledge base does not support; say so when nothing relevant is found.

          #{format_hits(hits)}
          </knowledge_base>
        MD
      end
    end
  end
end
