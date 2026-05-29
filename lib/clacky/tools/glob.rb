# frozen_string_literal: true

require "pathname"

module Clacky
  module Tools
    class Glob < Base
      # Maximum file size to search (1MB)
      MAX_FILE_SIZE = 1_048_576

      self.tool_name = "glob"
      self.tool_description = "Find files matching a glob pattern (e.g., '**/*.rb', 'src/**/*.js'). " \
                              "Returns file paths sorted by modification time. Respects .gitignore patterns."
      self.tool_category = "file_system"
      self.tool_parameters = {
        type: "object",
        properties: {
          pattern: {
            type: "string",
            description: "The glob pattern to match files (e.g., '**/*.rb', 'lib/**/*.rb', '*.txt')"
          },
          base_path: {
            type: "string",
            description: "The base directory to search in (defaults to current directory)",
            default: "."
          },
          limit: {
            type: "integer",
            description: "Maximum number of results to return (default: 10)",
            default: 10
          }
        },
        required: %w[pattern]
      }

      def execute(pattern:, base_path: ".", limit: 10, working_dir: nil)
        # Validate pattern
        if pattern.nil? || pattern.strip.empty?
          return { error: "Pattern cannot be empty" }
        end

        # Expand ~ in pattern only (pattern is relative to base_path, not working_dir)
        pattern = pattern.start_with?("~") ? File.expand_path(pattern) : pattern
        # Expand base_path fully (~ and relative paths resolved against working_dir)
        base_path = expand_path(base_path, working_dir: working_dir)

        # Validate base_path
        unless Dir.exist?(base_path)
          return { error: "Base path does not exist: #{base_path}" }
        end

        if Clacky::Utils::FileIgnoreHelper.dangerous_root?(base_path)
          return {
            error: "Refusing to recursively glob from broad path '#{base_path}'. " \
                   "Narrow base_path to a specific subdirectory, " \
                   "or use '.' to search the working directory."
          }
        end

        begin
          expanded_path = base_path

          skipped = {
            binary: 0,
            too_large: 0,
            ignored: 0
          }

          # Auto-expand bare patterns (no slash, no **) to recursive search.
          effective_pattern = if !File.absolute_path?(pattern) &&
                                  !pattern.include?("/") &&
                                  !pattern.start_with?("**")
                                "**/#{pattern}"
                              else
                                pattern
                              end

          fnmatch_flags = File::FNM_PATHNAME | File::FNM_DOTMATCH

          matches = []
          walk_status = {}
          Clacky::Utils::FileIgnoreHelper.walk_files(expanded_path, skipped: skipped, status: walk_status) do |file|
            relative = file[(expanded_path.length + 1)..]

            unless File.fnmatch(effective_pattern, relative, fnmatch_flags)
              next
            end

            if Clacky::Utils::FileProcessor.binary_file_path?(file) &&
               !Clacky::Utils::FileProcessor.glob_allowed_binary?(file)
              skipped[:binary] += 1
              next
            end

            if File.size(file) > MAX_FILE_SIZE
              skipped[:too_large] += 1
              next
            end

            matches << file
          end

          # Sort by modification time (most recent first)
          matches = matches.sort_by { |path| -File.mtime(path).to_i }

          # Apply limit
          total_matches = matches.length
          matches = matches.take(limit)

          # Convert to absolute paths
          matches = matches.map { |path| File.expand_path(path) }

          walk_truncated = walk_status[:truncated] == true
          {
            matches: matches,
            total_matches: total_matches,
            returned: matches.length,
            truncated: total_matches > limit || walk_truncated,
            truncation_reason: walk_status[:truncation_reason],
            skipped_files: skipped,
            error: nil
          }
        rescue StandardError => e
          { error: "Failed to glob files: #{e.message}" }
        end
      end

      def format_call(args)
        pattern = args[:pattern] || args['pattern'] || ''
        base_path = args[:base_path] || args['base_path'] || '.'
        
        display_base = base_path == '.' ? '' : " in #{base_path}"
        "glob(\"#{pattern}\"#{display_base})"
      end

      def format_result(result)
        if result[:error]
          "[Error] #{result[:error]}"
        else
          count = result[:returned] || 0
          total = result[:total_matches] || 0
          truncated = result[:truncated] ? " (truncated)" : ""

          msg = "[OK] Found #{count}/#{total} files#{truncated}"

          if result[:truncation_reason]
            msg += " [walk #{result[:truncation_reason]}]"
          end

          # Add skipped files info if present
          if result[:skipped_files]
            skipped = result[:skipped_files]
            skipped_parts = []
            skipped_parts << "#{skipped[:ignored]} ignored" if skipped[:ignored] > 0
            skipped_parts << "#{skipped[:binary]} binary" if skipped[:binary] > 0
            skipped_parts << "#{skipped[:too_large]} too large" if skipped[:too_large] > 0
            
            msg += " (skipped: #{skipped_parts.join(', ')})" unless skipped_parts.empty?
          end
          
          msg
        end
      end
    end
  end
end
