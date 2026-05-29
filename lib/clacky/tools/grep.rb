# frozen_string_literal: true

module Clacky
  module Tools
    class Grep < Base
      # Maximum file size to search (1MB)
      MAX_FILE_SIZE = 1_048_576

      # Maximum line length to display (to avoid huge outputs)
      MAX_LINE_LENGTH = 500

      self.tool_name = "grep"
      self.tool_description = "Search file contents using regular expressions. Returns matching lines with context."
      self.tool_category = "file_system"
      self.tool_parameters = {
        type: "object",
        properties: {
          pattern: {
            type: "string",
            description: "The regular expression pattern to search for"
          },
          path: {
            type: "string",
            description: "File or directory to search in (defaults to current directory)",
            default: "."
          },
          file_pattern: {
            type: "string",
            description: "Glob pattern to filter files (e.g., '*.rb', '**/*.js')",
            default: "**/*"
          },
          case_insensitive: {
            type: "boolean",
            description: "Perform case-insensitive search",
            default: false
          },
          context_lines: {
            type: "integer",
            description: "Number of context lines to show before and after each match (max: 10)",
            default: 0
          },
          max_files: {
            type: "integer",
            description: "Maximum number of matching files to return",
            default: 50
          },
          max_matches_per_file: {
            type: "integer",
            description: "Maximum number of matches to return per file",
            default: 50
          },
          max_total_matches: {
            type: "integer",
            description: "Maximum total number of matches to return across all files",
            default: 200
          },
          max_file_size: {
            type: "integer",
            description: "Maximum file size in bytes to search (default: 1MB)",
            default: MAX_FILE_SIZE
          },
        },
        required: %w[pattern]
      }

      def execute(
        pattern:,
        path: ".",
        file_pattern: "**/*",
        case_insensitive: false,
        context_lines: 0,
        max_files: 50,
        max_matches_per_file: 50,
        max_total_matches: 200,
        max_file_size: MAX_FILE_SIZE,
        max_files_to_search: 10000,
        working_dir: nil
      )
        # Validate pattern
        if pattern.nil? || pattern.strip.empty?
          return { error: "Pattern cannot be empty" }
        end

        # Validate and expand path relative to working_dir when provided
        begin
          expanded_path = expand_path(path, working_dir: working_dir)
        rescue StandardError => e
          return { error: "Invalid path: #{e.message}" }
        end

        unless File.exist?(expanded_path)
          return { error: "Path does not exist: #{path}" }
        end

        if File.directory?(expanded_path) && Clacky::Utils::FileIgnoreHelper.dangerous_root?(expanded_path)
          return {
            error: "Refusing to recursively grep from broad path '#{path}'. " \
                   "Narrow the path to a specific subdirectory, " \
                   "or use '.' to search the working directory."
          }
        end

        # Limit context_lines
        context_lines = [[context_lines, 0].max, 10].min

        begin
          # Compile regex
          regex_options = case_insensitive ? Regexp::IGNORECASE : 0
          regex = Regexp.new(pattern, regex_options)

          results = []
          total_matches = 0
          files_searched = 0
          skipped = {
            binary: 0,
            too_large: 0,
            ignored: 0
          }
          truncation_reason = nil

          files = if File.file?(expanded_path)
                    [expanded_path]
                  else
                    fnmatch_flags = File::FNM_PATHNAME | File::FNM_DOTMATCH
                    collected = []
                    walk_status = {}
                    Clacky::Utils::FileIgnoreHelper.walk_files(expanded_path, skipped: skipped, status: walk_status) do |f|
                      relative = f[(expanded_path.length + 1)..]
                      collected << f if File.fnmatch(file_pattern, relative, fnmatch_flags)
                    end
                    if walk_status[:truncated]
                      truncation_reason ||= "walk #{walk_status[:truncation_reason]}"
                    end
                    collected
                  end

          files.each do |file|
            if files_searched >= max_files_to_search
              truncation_reason ||= "max_files_to_search limit reached"
              break
            end

            # Skip binary files
            if Clacky::Utils::FileProcessor.binary_file_path?(file)
              skipped[:binary] += 1
              next
            end

            # Skip files that are too large
            if File.size(file) > max_file_size
              skipped[:too_large] += 1
              next
            end

            files_searched += 1

            # Check if we've found enough matching files
            if results.length >= max_files
              truncation_reason ||= "max_files limit reached"
              break
            end

            # Check if we've found enough total matches
            if total_matches >= max_total_matches
              truncation_reason ||= "max_total_matches limit reached"
              break
            end

            # Search the file
            matches = search_file(file, regex, context_lines, max_matches_per_file)
            next if matches.empty?

            # Add remaining matches respecting max_total_matches
            remaining_matches = max_total_matches - total_matches
            matches = matches.take(remaining_matches) if remaining_matches < matches.length

            results << {
              file: File.expand_path(file),
              matches: matches
            }
            total_matches += matches.length
          end

          {
            results: results,
            total_matches: total_matches,
            files_searched: files_searched,
            files_with_matches: results.length,
            skipped_files: skipped,
            truncated: !truncation_reason.nil?,
            truncation_reason: truncation_reason,
            error: nil
          }
        rescue RegexpError => e
          { error: "Invalid regex pattern: #{e.message}" }
        rescue StandardError => e
          { error: "Failed to search files: #{e.message}" }
        end
      end

      def format_call(args)
        pattern = args[:pattern] || args['pattern'] || ''
        path = args[:path] || args['path'] || '.'

        # Truncate pattern if too long
        display_pattern = pattern.length > 30 ? "#{pattern[0..27]}..." : pattern
        display_path = path == '.' ? 'current dir' : (path.length > 20 ? "...#{path[-17..]}" : path)

        "grep(\"#{display_pattern}\" in #{display_path})"
      end

      def format_result(result)
        if result[:error]
          "[Error] #{result[:error]}"
        else
          matches = result[:total_matches] || 0
          files = result[:files_with_matches] || 0
          msg = "[OK] Found #{matches} matches in #{files} files"

          # Add truncation info if present
          if result[:truncated] && result[:truncation_reason]
            msg += " (truncated: #{result[:truncation_reason]})"
          end

          msg
        end
      end

      # Format result for LLM consumption - return a compact version to save tokens
      def format_result_for_llm(result)
        # If there's an error, return it as-is
        return result if result[:error]

        # Build a compact summary with file list and sample matches
        compact = {
          summary: {
            total_matches: result[:total_matches],
            files_with_matches: result[:files_with_matches],
            files_searched: result[:files_searched],
            truncated: result[:truncated],
            truncation_reason: result[:truncation_reason]
          }
        }

        # Include list of files with match counts
        if result[:results] && !result[:results].empty?
          compact[:files] = result[:results].map do |file_result|
            {
              file: file_result[:file],
              match_count: file_result[:matches].length
            }
          end

          # Include sample matches (first 2 matches from first 3 files) for context
          sample_results = result[:results].take(3)
          compact[:sample_matches] = sample_results.map do |file_result|
            {
              file: file_result[:file],
              matches: file_result[:matches].take(2).map do |match|
                {
                  line_number: match[:line_number],
                  line: match[:line]
                  # Omit context to save space - it's rarely needed by LLM
                }
              end
            }
          end
        end

        compact
      end


      def search_file(file, regex, context_lines, max_matches)
        matches = []

        # Use File.foreach for memory-efficient line-by-line reading.
        # Scrub invalid UTF-8 bytes so results survive JSON encoding.
        File.foreach(file, chomp: true).with_index do |raw_line, index|
          line = safe_utf8(raw_line)
          # Stop if we have enough matches for this file
          break if matches.length >= max_matches

          next unless line.match?(regex)

          # Truncate long lines
          display_line = line.length > MAX_LINE_LENGTH ? "#{line[0...MAX_LINE_LENGTH]}..." : line

          # Get context if requested
          if context_lines > 0
            context = get_line_context(file, index, context_lines)
          else
            context = nil
          end

          matches << {
            line_number: index + 1,
            line: display_line,
            context: context
          }
        end

        matches
      rescue StandardError
        []
      end

      # Get context lines around a match
      def get_line_context(file, match_index, context_lines)
        lines = File.readlines(file, chomp: true).map! { |l| safe_utf8(l) }
        start_line = [0, match_index - context_lines].max
        end_line = [lines.length - 1, match_index + context_lines].min

        context = []
        (start_line..end_line).each do |i|
          line_content = lines[i]
          # Truncate long lines in context too
          display_content = line_content.length > MAX_LINE_LENGTH ?
                          "#{line_content[0...MAX_LINE_LENGTH]}..." :
                          line_content

          context << {
            line_number: i + 1,
            content: display_content,
            is_match: i == match_index
          }
        end

        context
      rescue StandardError
        nil
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
