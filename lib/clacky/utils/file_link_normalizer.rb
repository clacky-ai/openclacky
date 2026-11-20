# frozen_string_literal: true

require "base64"

module Clacky
  module Utils
    # Rewrites local file references in assistant markdown links to file:///abs/path.
    module FileLinkNormalizer
      SKIP_PREFIXES = %w[/api/ /preview/ /ext_ui/ /agent_ui/ http:// https:// mailto: #].freeze

      # Models can emit local files as hosted-platform references
      # (`/workspace/projects/<base64url>` decoding to `cch1:file:///abs/path`) or
      # as bare absolute paths. Neither matches the `file://` handler in the Web UI
      # or IM delivery, so they render as dead links. Rewrite every resolvable one
      # to `file:///abs/path`.
      def self.normalize(content)
        return content if content.nil? || content.empty?

        content.gsub(/\]\(([^)\s]+)\)/) do |match|
          path = local_file_path($1)
          path ? "](file://#{path})" : match
        end
      end

      def self.local_file_path(href)
        return nil if href.empty?

        if (token = project_ref_token(href))
          candidate = decode_project_ref(token)
        elsif SKIP_PREFIXES.any? { |prefix| href.start_with?(prefix) }
          return nil
        else
          candidate = href
        end
        return nil if candidate.nil?

        candidate = candidate.sub(/\Acch1:/, "").sub(/\Afile:\/{2,3}/, "/")
        return nil unless candidate.start_with?("/")

        # Only rewrite paths that exist: otherwise a site route such as
        # `/docs/getting-started` would be turned into a dead file link.
        File.file?(candidate) ? candidate : nil
      end

      # Hosted-platform refs reach us both as `/workspace/projects/<token>` and as
      # a full URL against the local server origin.
      def self.project_ref_token(href)
        match = %r{\A(?:https?://[^/]+)?/workspace/projects/([A-Za-z0-9_\-=]+)\z}.match(href)
        match && match[1]
      end

      def self.decode_project_ref(token)
        padded = token + "=" * ((4 - token.length % 4) % 4)
        decoded = Base64.urlsafe_decode64(padded)
        decoded.force_encoding(::Encoding::UTF_8)
        return nil unless decoded.valid_encoding?
        return nil unless decoded.start_with?("cch1:file://", "file://")

        decoded
      rescue ArgumentError
        nil
      end
    end
  end
end
