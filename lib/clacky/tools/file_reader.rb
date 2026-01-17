# frozen_string_literal: true

require_relative "base"

module Clacky
  module Tools
    class FileReader < Base
      self.tool_name = "file_reader"
      self.tool_description = "Read contents of a file from the filesystem"
      self.tool_category = "file_system"
      self.tool_parameters = {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute or relative path to the file"
          },
          max_lines: {
            type: "integer",
            description: "Maximum number of lines to read (optional)",
            default: 1000
          }
        },
        required: ["path"]
      }

      def execute(path:, max_lines: 1000)
        # Expand ~ to home directory
        expanded_path = File.expand_path(path)
        
        unless File.exist?(expanded_path)
          return {
            path: expanded_path,
            content: nil,
            error: "File not found: #{expanded_path}"
          }
        end

        # If path is a directory, list its first-level contents (similar to filetree)
        if File.directory?(expanded_path)
          return list_directory_contents(expanded_path)
        end

        unless File.file?(expanded_path)
          return {
            path: expanded_path,
            content: nil,
            error: "Path is not a file: #{expanded_path}"
          }
        end

        begin
          lines = File.readlines(expanded_path).first(max_lines)
          content = lines.join
          truncated = File.readlines(expanded_path).size > max_lines

          {
            path: expanded_path,
            content: content,
            lines_read: lines.size,
            truncated: truncated,
            error: nil
          }
        rescue StandardError => e
          {
            path: expanded_path,
            content: nil,
            error: "Error reading file: #{e.message}"
          }
        end
      end

      def format_call(args)
        path = args[:path] || args['path']
        "Read(#{Utils::PathHelper.safe_basename(path)})"
      end

      def format_result(result)
        return result[:error] if result[:error]

        # Handle directory listing
        if result[:is_directory] || result['is_directory']
          entries = result[:entries_count] || result['entries_count'] || 0
          dirs = result[:directories_count] || result['directories_count'] || 0
          files = result[:files_count] || result['files_count'] || 0
          return "Listed #{entries} entries (#{dirs} directories, #{files} files)"
        end

        # Handle file reading
        lines = result[:lines_read] || result['lines_read'] || 0
        truncated = result[:truncated] || result['truncated']
        "Read #{lines} lines#{truncated ? ' (truncated)' : ''}"
      end

      private

      # List first-level directory contents (files and directories)
      def list_directory_contents(path)
        begin
          entries = Dir.entries(path).reject { |entry| entry == "." || entry == ".." }
          
          # Separate files and directories
          files = []
          directories = []
          
          entries.each do |entry|
            full_path = File.join(path, entry)
            if File.directory?(full_path)
              directories << entry + "/"
            else
              files << entry
            end
          end
          
          # Sort directories and files separately, then combine
          directories.sort!
          files.sort!
          all_entries = directories + files
          
          # Format as a tree-like structure
          content = all_entries.map { |entry| "  #{entry}" }.join("\n")
          
          {
            path: path,
            content: "Directory listing:\n#{content}",
            entries_count: all_entries.size,
            directories_count: directories.size,
            files_count: files.size,
            is_directory: true,
            error: nil
          }
        rescue StandardError => e
          {
            path: path,
            content: nil,
            error: "Error reading directory: #{e.message}"
          }
        end
      end
    end
  end
end
