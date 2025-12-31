# frozen_string_literal: true

require_relative "base"

module Clacky
  module Tools
    class Shell < Base
      self.tool_name = "shell"
      self.tool_description = "Execute shell commands in the terminal"
      self.tool_category = "system"
      self.tool_parameters = {
        type: "object",
        properties: {
          command: {
            type: "string",
            description: "Shell command to execute"
          }
        },
        required: ["command"]
      }

      TIMEOUT = 30 # seconds

      def execute(command:)
        require "open3"
        require "timeout"

        begin
          stdout, stderr, status = Timeout.timeout(TIMEOUT) do
            Open3.capture3(command)
          end

          {
            command: command,
            stdout: stdout,
            stderr: stderr,
            exit_code: status.exitstatus,
            success: status.success?
          }
        rescue Timeout::Error
          {
            command: command,
            stdout: "",
            stderr: "Command timed out after #{TIMEOUT} seconds",
            exit_code: -1,
            success: false
          }
        rescue StandardError => e
          {
            command: command,
            stdout: "",
            stderr: "Error executing command: #{e.message}",
            exit_code: -1,
            success: false
          }
        end
      end
    end
  end
end
