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
        unless File.exist?(path)
          return {
            path: path,
            content: nil,
            error: "File not found: #{path}"
          }
        end

        unless File.file?(path)
          return {
            path: path,
            content: nil,
            error: "Path is not a file: #{path}"
          }
        end

        begin
          lines = File.readlines(path).first(max_lines)
          content = lines.join
          truncated = File.readlines(path).size > max_lines

          {
            path: path,
            content: content,
            lines_read: lines.size,
            truncated: truncated,
            error: nil
          }
        rescue StandardError => e
          {
            path: path,
            content: nil,
            error: "Error reading file: #{e.message}"
          }
        end
      end
    end
  end
end
