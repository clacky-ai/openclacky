# frozen_string_literal: true

require 'json'

module Clacky
  module DeployTools
    # Execute deployment and monitor until completion
    class ExecuteDeployment
      MAX_WAIT_TIME = 600 # 10 minutes
      POLL_INTERVAL = 5   # 5 seconds

      # Execute deployment for a service
      #
      # @param service_name [String] Service to deploy
      # @return [Hash] Result of the deployment
      def self.execute(service_name:)
        if service_name.nil? || service_name.empty?
          return {
            error: "Service name is required",
            details: "Please provide a valid service name"
          }
        end

        puts "🚀 Starting deployment for service: #{service_name}"
        
        # Trigger deployment
        command = "clackycli up -s #{shell_escape(service_name)} -d"
        output = `#{command} 2>&1`
        exit_code = $?.exitstatus

        if exit_code != 0
          return {
            error: "Failed to trigger deployment",
            details: output,
            exit_code: exit_code,
            service: service_name
          }
        end

        puts "✅ Deployment triggered successfully"
        puts "⏳ Monitoring deployment progress..."

        # Monitor deployment status
        result = monitor_deployment(service_name)
        result[:service] = service_name
        result
      end

      # Monitor deployment status until completion or timeout
      #
      # @param service_name [String] Service name
      # @return [Hash] Deployment result
      def self.monitor_deployment(service_name)
        start_time = Time.now
        last_status = nil

        loop do
          elapsed = Time.now - start_time
          
          if elapsed > MAX_WAIT_TIME
            return {
              success: false,
              error: "Deployment timeout",
              details: "Deployment exceeded maximum wait time of #{MAX_WAIT_TIME} seconds",
              elapsed: elapsed
            }
          end

          # Get deployment status
          status = get_deployment_status(service_name)
          
          # Print status update if changed
          if status[:current_status] != last_status
            puts "📊 Status: #{status[:current_status]}"
            last_status = status[:current_status]
          end

          # Check if deployment completed
          if status[:completed]
            if status[:success]
              return {
                success: true,
                message: "Deployment completed successfully",
                elapsed: elapsed,
                final_status: status[:current_status]
              }
            else
              return {
                success: false,
                error: "Deployment failed",
                details: status[:error_message],
                elapsed: elapsed,
                final_status: status[:current_status]
              }
            end
          end

          # Wait before next poll
          sleep POLL_INTERVAL
        end
      end

      # Get current deployment status
      #
      # @param service_name [String] Service name
      # @return [Hash] Status information
      def self.get_deployment_status(service_name)
        command = "clackycli service list --json"
        output = `#{command} 2>&1`
        
        begin
          services = JSON.parse(output)
          service = services.find { |s| s['name'] == service_name }
          
          if service.nil?
            return {
              completed: true,
              success: false,
              error_message: "Service not found: #{service_name}"
            }
          end

          # Get latest deployment
          deployments = service['deployments'] || []
          latest = deployments.first
          
          if latest.nil?
            return {
              completed: false,
              current_status: 'waiting'
            }
          end

          status = latest['status']
          
          case status
          when 'SUCCESS', 'ACTIVE'
            {
              completed: true,
              success: true,
              current_status: status
            }
          when 'FAILED', 'CRASHED'
            {
              completed: true,
              success: false,
              current_status: status,
              error_message: latest['error'] || 'Deployment failed'
            }
          else
            {
              completed: false,
              current_status: status
            }
          end
        rescue JSON::ParserError
          {
            completed: true,
            success: false,
            error_message: "Failed to parse deployment status"
          }
        end
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
