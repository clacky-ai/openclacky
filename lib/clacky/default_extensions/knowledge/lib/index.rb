# frozen_string_literal: true

module Clacky
  module Knowledge
    # In-memory BM25 over paragraph chunks. Chinese runs are split into
    # overlapping character bigrams (single char when the run is 1 long);
    # Latin letters / digits become lower-cased words. No dictionary needed.
    #
    # Kept behind #search(query, limit:) so a hybrid (BM25 + vector) backend
    # can replace it later without touching the hook or tools.
    class Index
      Chunk = Struct.new(:entry, :text, :terms, :length, keyword_init: true)
      Hit = Struct.new(:entry, :text, :score, keyword_init: true)

      K1 = 1.2
      B = 0.75
      CHUNK_CHARS = 600

      def self.tokenize(text)
        text.to_s.downcase.scan(/\p{Han}+|[a-z0-9]+/).flat_map do |run|
          next [run] unless run.match?(/\p{Han}/)
          run.length == 1 ? [run] : run.chars.each_cons(2).map(&:join)
        end
      end

      def initialize(entries)
        @chunks = entries.flat_map { |e| chunk(e) }
        @df = Hash.new(0)
        @chunks.each { |c| c.terms.each_key { |t| @df[t] += 1 } }
        total = @chunks.sum(&:length)
        @avg_len = @chunks.empty? ? 0.0 : total.to_f / @chunks.size
      end

      def size
        @chunks.size
      end

      # Best chunk per entry, highest score first.
      def search(query, limit: 5)
        terms = self.class.tokenize(query).uniq
        return [] if terms.empty? || @chunks.empty?

        best = {}
        @chunks.each do |c|
          score = terms.sum { |t| term_score(c, t) }
          next unless score > 0
          prev = best[c.entry.id]
          best[c.entry.id] = Hit.new(entry: c.entry, text: c.text, score: score) if prev.nil? || score > prev.score
        end
        best.values.sort_by { |h| -h.score }.first(limit)
      end

      private def term_score(chunk, term)
        tf = chunk.terms[term]
        return 0.0 unless tf
        n = @chunks.size
        idf = Math.log(1 + (n - @df[term] + 0.5) / (@df[term] + 0.5))
        idf * tf * (K1 + 1) / (tf + K1 * (1 - B + B * chunk.length / @avg_len))
      end

      # Paragraphs merged up to CHUNK_CHARS; the title is prepended to every
      # chunk's terms so a title match lifts all of its paragraphs.
      private def chunk(entry)
        paras = entry.body.split(/\n\s*\n/).map(&:strip).reject(&:empty?)
        texts = []
        paras.each do |p|
          if texts.empty? || texts.last.length + p.length > CHUNK_CHARS
            texts << p.dup
          else
            texts.last << "\n\n" << p
          end
        end
        texts = [""] if texts.empty?
        texts.map do |text|
          tokens = self.class.tokenize("#{entry.title}\n#{text}")
          Chunk.new(entry: entry, text: text, terms: tokens.tally, length: tokens.size)
        end
      end
    end
  end
end
