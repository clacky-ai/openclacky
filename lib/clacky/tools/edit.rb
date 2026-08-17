# frozen_string_literal: true

module Clacky
  module Tools
    class Edit < Base
      self.tool_name = "edit"
      self.tool_description = "Make precise edits to existing files by replacing old text with new text. " \
                              "The old_string must match exactly (including whitespace and indentation)."
      self.tool_category = "file_system"
      self.tool_parameters = {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "The path of the file to edit (absolute or relative)"
          },
          old_string: {
            type: "string",
            description: "The exact string to find and replace (must match exactly including whitespace)"
          },
          new_string: {
            type: "string",
            description: "The new string to replace the old string with"
          },
          replace_all: {
            type: "boolean",
            description: "If true, replace all occurrences. If false (default), replace only the first occurrence",
            default: false
          }
        },
        required: %w[path old_string new_string]
      }

      def execute(path:, old_string:, new_string:, replace_all: false, working_dir: nil)
        # Expand ~ to home directory, resolve relative paths against working_dir
        path = expand_path(path, working_dir: working_dir)

        unless File.exist?(path)
          return { error: "File not found: #{path}" }
        end

        unless File.file?(path)
          return { error: "Path is not a file: #{path}" }
        end

        begin
          # Scrub invalid UTF-8 bytes at read time — otherwise editing a file
          # that contains non-UTF-8 bytes would poison history / error messages
          # and cause JSON.generate to fail during replay.
          content = safe_utf8(File.read(path))

          # Detect the file's dominant line-ending style BEFORE any
          # modification. Windows-created files (and /mnt/c on WSL) use
          # CRLF; AI-supplied old_string/new_string always use LF. Without
          # preservation, the replaced fragment introduces LF into a CRLF
          # file, creating mixed line endings that confuse Git diff and
          # Windows IDEs.
          preserve_crlf = content.include?("\r\n")

          # Find matching string using layered strategy (shared with preview)
          match_result = Utils::StringMatcher.find_match(content, old_string)

          unless match_result
            return build_helpful_error(content, old_string, path)
          end

          actual_old_string = match_result[:matched_string]
          occurrences = match_result[:occurrences]

          # If not replace_all and multiple occurrences, warn about ambiguity
          if !replace_all && occurrences > 1
            return {
              error: "String appears #{occurrences} times in the file. Use replace_all: true to replace all occurrences, " \
                     "or provide a more specific string that appears only once."
            }
          end

          # Perform literal replacement.
          #
          # NOTE: Use the block form (`sub(old) { new }`) instead of the
          # two-arg form (`sub(old, new)`). The two-arg form interprets
          # backslash escapes (\&, \1, \`, \', \\) in the replacement
          # as sed-style backreferences, silently mangling literal
          # backslashes and these escape sequences. The block form
          # performs no such interpretation, matching the edit tool's
          # literal-replacement contract.
          content = if replace_all
                      content.gsub(actual_old_string) { new_string }
                    else
                      content.sub(actual_old_string) { new_string }
                    end

          # Preserve the original line-ending style: if the file was CRLF,
          # re-normalize the entire content to CRLF so the newly inserted
          # LF fragments (from new_string) match the rest of the file.
          content = normalize_line_endings(content, :crlf) if preserve_crlf

          File.write(path, content)

          {
            path: File.expand_path(path),
            replacements: replace_all ? occurrences : 1,
            error: nil
          }
        rescue Errno::EACCES => e
          { error: "Permission denied: #{e.message}" }
        rescue StandardError => e
          { error: "Failed to edit file: #{e.message}" }
        end
      end

      private def build_helpful_error(content, old_string, path)
        old_lines = old_string.lines
        first_line_pattern = old_lines.first&.strip

        if first_line_pattern && !first_line_pattern.empty?
          content_lines = content.lines
          similar_locations = []

          content_lines.each_with_index do |line, idx|
            if line.strip == first_line_pattern
              start_idx = [0, idx - 2].max
              end_idx = [content_lines.length - 1, idx + old_lines.length + 2].min
              context = content_lines[start_idx..end_idx].join
              similar_locations << { line_number: idx + 1, context: context }
            end
          end

          if similar_locations.any?
            context_display = similar_locations.first[:context].lines.first(5).map { |l| "  #{l}" }.join
            return {
              error: "String to replace not found in file. The first line of old_string exists at line #{similar_locations.first[:line_number]}, " \
                     "but the full multi-line string doesn't match. This is often caused by whitespace differences (tabs vs spaces). " \
                     "\n\nContext around line #{similar_locations.first[:line_number]}:\n#{context_display}\n\n" \
                     "TIP: Use file_reader to see the actual content, then retry. No need to explain, just execute the tools."
            }
          end
        end

        {
          error: "String to replace not found in file '#{File.basename(path)}'. " \
                 "Make sure old_string matches exactly (including all whitespace). " \
                 "TIP: Use file_reader to view the exact content first, then retry. No need to explain, just execute the tools."
        }
      end

      def format_call(args)
        path = args[:file_path] || args["file_path"] || args[:path] || args["path"]
        "Edit(#{Utils::PathHelper.safe_basename(path)})"
      end

      def format_result(result)
        return result[:error] if result[:error]

        replacements = result[:replacements] || result["replacements"] || 1
        "Modified #{replacements} occurrence#{replacements > 1 ? "s" : ""}"
      end

      # Normalize all line endings in `content` to the given style.
      # Works by first collapsing everything to LF, then expanding to the
      # target — this avoids double-converting existing CRLF into CRCRLF.
      # @param content [String]
      # @param style [Symbol] :crlf or :lf
      # @return [String]
      private def normalize_line_endings(content, style)
        case style
        when :crlf
          content.gsub(/\r\n/, "\n").gsub(/\r/, "\n").gsub(/\n/, "\r\n")
        else
          content.gsub(/\r\n/, "\n").gsub(/\r/, "\n")
        end
      end

      # Scrub invalid UTF-8 byte sequences (see file_reader.rb for rationale).
      private def safe_utf8(str)
        return str if str.nil?
        return str if str.encoding == Encoding::UTF_8 && str.valid_encoding?
        str.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\u{FFFD}")
      end
    end
  end
end
