# frozen_string_literal: true

module Clacky
  module Utils
    # Parse the YAML frontmatter block at the top of a Markdown file.
    #
    # Frontmatter is authored by users and by the LLM, so it is not guaranteed
    # to be valid YAML. Two failure modes must never cost the whole block:
    #
    #   * Values YAML types itself — a bare `updated_at: 2026-05-07` becomes a
    #     Date, which `YAML.safe_load` rejects unless the class is permitted.
    #     Legacy memory files written before v1.5.24 still carry such fields.
    #   * Values that break the YAML grammar — an unquoted `description` that
    #     contains ": " is enough to raise.
    #
    # The first is handled by permitting Date/Time; the second degrades to a
    # line-wise scan so `topic` / `description` survive a malformed neighbour.
    module Frontmatter
      # `---` fence, body, closing `---`. CRLF tolerated for files edited on
      # Windows. Anchored so a horizontal rule mid-document is never matched.
      PATTERN = /\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)/m.freeze

      # Single `key: value` line. Indented lines are skipped on purpose so the
      # fallback never picks up nested mappings or block-scalar content.
      FIELD_LINE = /\A([A-Za-z_][A-Za-z0-9_-]*):[ \t]*(.*?)[ \t]*\z/.freeze

      # @param content [String] full file content
      # @return [Hash] frontmatter as a string-keyed hash; empty when absent
      def self.parse(content)
        match = content.to_s.match(PATTERN)
        return {} unless match

        body = match[1]
        data = YAMLCompat.safe_load(body, permitted_classes: [::Date, ::Time])
        data.is_a?(Hash) ? data : {}
      rescue Psych::Exception
        scan_fields(body)
      end

      # Line-wise `key: value` extraction used when the block is not valid YAML.
      # First occurrence wins, matching how a YAML duplicate key would be read.
      #
      # @param body [String] raw frontmatter body
      # @return [Hash]
      def self.scan_fields(body)
        fields = {}
        body.each_line do |line|
          m = line.chomp.match(FIELD_LINE)
          next unless m
          next if fields.key?(m[1])

          fields[m[1]] = unquote(m[2])
        end
        fields
      end

      def self.unquote(value)
        m = value.match(/\A(["'])(.*)\1\z/m)
        m ? m[2] : value
      end
    end
  end
end
