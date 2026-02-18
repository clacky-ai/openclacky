# frozen_string_literal: true

module Clacky
  module DeployTools
    # Report deployment status to user with formatted output
    class ReportDeployStatus
      VALID_STATUSES = %w[analyzing deploying checking success failed].freeze
      
      STATUS_ICONS = {
        'analyzing' => '🔍',
        'deploying' => '🚀',
        'checking' => '✅',
        'success' => '🎉',
        'failed' => '❌'
      }.freeze

      STATUS_COLORS = {
        'analyzing' => :cyan,
        'deploying' => :yellow,
        'checking' => :blue,
        'success' => :green,
        'failed' => :red
      }.freeze

      # Execute the report_deploy_status command
      #
      # @param status [String] Deployment status (analyzing, deploying, checking, success, failed)
      # @param message [String] Status message to display
      # @return [Hash] Result of the report operation
      def self.execute(status:, message:)
        unless VALID_STATUSES.include?(status)
          return {
            error: "Invalid status",
            details: "Status must be one of: #{VALID_STATUSES.join(', ')}",
            provided: status
          }
        end

        icon = STATUS_ICONS[status]
        formatted_message = format_message(status, message, icon)
        
        # Output to stdout
        puts formatted_message
        
        {
          success: true,
          status: status,
          message: message,
          timestamp: Time.now.iso8601
        }
      end

      # Format the status message with icon and styling
      #
      # @param status [String] Deployment status
      # @param message [String] Status message
      # @param icon [String] Emoji icon for status
      # @return [String] Formatted message
      def self.format_message(status, message, icon)
        timestamp = Time.now.strftime("%H:%M:%S")
        status_label = status.upcase.ljust(10)
        
        "#{icon} [#{timestamp}] #{status_label} #{message}"
      end
    end
  end
end
