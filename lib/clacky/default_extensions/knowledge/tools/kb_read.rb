# frozen_string_literal: true

require_relative "../lib/knowledge"

module Clacky
  module Tools
    class KbRead < Base
      MAX_CHARS = 20_000
      MAX_MATCHES = 50

      self.tool_name = "kb_read"
      self.tool_description = "Read one knowledge base entry by id (from kb_search or [K#] passages). " \
                              "Pass `pattern` to grep inside that entry instead of reading it whole."
      self.tool_parameters = {
        type: "object", properties: {
          id: { type: "string", description: "Entry id" },
          pattern: { type: "string", description: "Optional regex / text to grep within the entry" },
          context: { type: "integer", description: "Lines of context around each match (default 2)" }
        }, required: %w[id]
      }

      def format_call(args)
        id = args[:id] || args["id"]
        pattern = args[:pattern] || args["pattern"]
        pattern ? "kb_read(#{id}, /#{pattern}/)" : "kb_read(#{id})"
      end

      def execute(id:, pattern: nil, context: 2, **)
        return { error: "Knowledge base is empty or turned off" } unless Clacky::Knowledge.enabled?

        entry = Clacky::Knowledge.store.find(id)
        return { error: "No entry with id #{id.inspect}. Use kb_search to find ids." } unless entry

        meta = { id: entry.id, title: entry.title, folder: (entry.folder unless entry.folder.to_s.empty?), source: entry.source }.compact
        return meta.merge(grep(entry.body, pattern, context.to_i.clamp(0, 10))) if pattern && !pattern.strip.empty?

        body = entry.body
        truncated = body.length > MAX_CHARS
        meta.merge(content: truncated ? body[0, MAX_CHARS] : body,
                   truncated: truncated, note: (truncated ? "Truncated; use pattern to grep the rest." : nil)).compact
      end

      private def grep(body, pattern, ctx)
        re = begin
          Regexp.new(pattern, Regexp::IGNORECASE)
        rescue RegexpError
          Regexp.new(Regexp.escape(pattern), Regexp::IGNORECASE)
        end
        lines = body.lines
        hits = lines.each_index.select { |i| lines[i].match?(re) }
        return { matches: 0, content: "No lines match #{pattern.inspect}." } if hits.empty?

        blocks = hits.first(MAX_MATCHES).map do |i|
          from = [i - ctx, 0].max
          to = [i + ctx, lines.size - 1].min
          (from..to).map { |j| "#{j + 1}: #{lines[j].chomp}" }.join("\n")
        end
        { matches: hits.size, content: blocks.join("\n--\n") }
      end
    end
  end
end
