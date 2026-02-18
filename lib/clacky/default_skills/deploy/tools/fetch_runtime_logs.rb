# frozen_string_literal: true

module Clacky
  module DeployTools
    # Fetch runtime logs from deployed service
    class FetchRuntimeLogs
      DEFAULT_LINES = 100
      MAX_LINES = 1000

      # Fetch runtime logs
      #
      # @param service_name [String] Service to fetch logs from
      # @param lines [Integer] Number of lines to fetch (default: 100)
      # @return [Hash] Result containing logs
      def self.execute(service_name:, lines: DEFAULT_LINES)
        if service_name.nil? || service_name.empty?
          return {
            error: "Service name is required",
            details: "Please provide a valid service name"
          }
        end

        # Validate lines parameter
        lines = lines.to_i
        if lines <= 0 || lines > MAX_LINES
          return {
            error: "Invalid lines parameter",
            details: "Lines must be between 1 and #{MAX_LINES}",
            provided: lines
          }
        end

        puts "📋 Fetching #{lines} lines of logs for service: #{service_name}"

        # Execute command
        command = "clackycli logs -s #{shell_escape(service_name)} --lines #{lines}"
        output = `#{command} 2>&1`
        exit_code = $?.exitstatus

        if exit_code != 0
          return {
            error: "Failed to fetch logs",
            details: output,
            exit_code: exit_code,
            service: service_name
          }
        end

        {
          success: true,
          service: service_name,
          lines_requested: lines,
          logs: output,
          timestamp: Time.now.iso8601
        }
      end

      # Escape shell arguments
      #
      # @param str [String] String to escape
      # @return [String] Escaped string
      def self.shell_escape(str)
        "'#{str.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
