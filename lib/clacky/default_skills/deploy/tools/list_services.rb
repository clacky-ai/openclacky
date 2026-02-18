# frozen_string_literal: true

module Clacky
  module DeployTools
    # List Railway services with environment variables (sensitive data masked)
    class ListServices
      SENSITIVE_PATTERNS = [
        /password/i,
        /secret/i,
        /api_key/i,
        /token/i,
        /credential/i,
        /private_key/i
      ].freeze

      # Execute the list_services command
      #
      # @return [Hash] Result containing services array
      def self.execute
        output = `clackycli service list --json 2>&1`
        exit_code = $?.exitstatus

        if exit_code != 0
          return {
            error: "Failed to list services",
            details: output,
            exit_code: exit_code
          }
        end

        begin
          services = JSON.parse(output)
          masked_services = mask_sensitive_data(services)
          
          {
            success: true,
            services: masked_services,
            count: masked_services.length
          }
        rescue JSON::ParserError => e
          {
            error: "Failed to parse Railway CLI output",
            details: e.message,
            raw_output: output
          }
        end
      end

      # Mask sensitive environment variable values
      #
      # @param services [Array<Hash>] Array of service objects
      # @return [Array<Hash>] Services with masked sensitive data
      def self.mask_sensitive_data(services)
        services.map do |service|
          service = service.dup
          
          if service['variables']
            service['variables'] = mask_variables(service['variables'])
          end
          
          service
        end
      end

      # Mask sensitive variable values
      #
      # @param variables [Hash] Environment variables
      # @return [Hash] Variables with sensitive values masked
      def self.mask_variables(variables)
        variables.transform_values do |value|
          next value unless value.is_a?(String)
          
          # Check if variable name matches sensitive patterns
          is_sensitive = SENSITIVE_PATTERNS.any? { |pattern| value =~ pattern }
          is_sensitive ? '******' : value
        end
      end
    end
  end
end
