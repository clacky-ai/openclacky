# frozen_string_literal: true

module Clacky
  module DeployTools
    # Set environment variables for a Railway service
    class SetDeployVariables
      PROTECTED_PREFIXES = ['CLACKY_'].freeze
      
      SENSITIVE_PATTERNS = [
        /password/i,
        /secret/i,
        /api_key/i,
        /token/i,
        /credential/i,
        /private_key/i
      ].freeze

      # Execute the set_deploy_variables command
      #
      # @param service_name [String] Target service name
      # @param variables [Hash] Simple variables (KEY => VALUE)
      # @param ref_variables [Hash] Reference variables (KEY => SERVICE.VAR)
      # @return [Hash] Result of the operation
      def self.execute(service_name:, variables: {}, ref_variables: {})
        # Validate service name
        if service_name.nil? || service_name.empty?
          return {
            error: "Service name is required",
            details: "Please provide a valid service name"
          }
        end

        results = {
          success: true,
          service: service_name,
          set_variables: [],
          skipped_variables: [],
          errors: []
        }

        # Set simple variables
        variables.each do |key, value|
          result = set_variable(service_name, key, value, is_reference: false)
          if result[:success]
            results[:set_variables] << { key: key, type: 'simple' }
          elsif result[:skipped]
            results[:skipped_variables] << { key: key, reason: result[:reason] }
          else
            results[:errors] << { key: key, error: result[:error] }
          end
        end

        # Set reference variables
        ref_variables.each do |key, reference|
          result = set_variable(service_name, key, reference, is_reference: true)
          if result[:success]
            results[:set_variables] << { key: key, type: 'reference' }
          elsif result[:skipped]
            results[:skipped_variables] << { key: key, reason: result[:reason] }
          else
            results[:errors] << { key: key, error: result[:error] }
          end
        end

        # Overall success if no errors occurred
        results[:success] = results[:errors].empty?
        results
      end

      # Set a single environment variable
      #
      # @param service_name [String] Service name
      # @param key [String] Variable name
      # @param value [String] Variable value or reference
      # @param is_reference [Boolean] Whether this is a reference variable
      # @return [Hash] Result of setting the variable
      def self.set_variable(service_name, key, value, is_reference:)
        # Skip protected variables
        if protected_variable?(key)
          return {
            success: false,
            skipped: true,
            reason: "Protected system variable (#{key})"
          }
        end

        # Build the command
        if is_reference
          command = "clackycli variables -s #{shell_escape(service_name)} --set-ref #{shell_escape(key)}=#{shell_escape(value)}"
        else
          command = "clackycli variables -s #{shell_escape(service_name)} --set #{shell_escape(key)}=#{shell_escape(value)}"
        end

        # Log (with sensitive masking)
        log_value = sensitive_variable?(key) ? '******' : value
        puts "Setting #{key}=#{log_value} on service #{service_name}"

        # Execute command
        output = `#{command} 2>&1`
        exit_code = $?.exitstatus

        if exit_code == 0
          { success: true }
        else
          {
            success: false,
            skipped: false,
            error: output.strip
          }
        end
      end

      # Check if a variable is protected
      #
      # @param key [String] Variable name
      # @return [Boolean] True if protected
      def self.protected_variable?(key)
        PROTECTED_PREFIXES.any? { |prefix| key.start_with?(prefix) }
      end

      # Check if a variable is sensitive
      #
      # @param key [String] Variable name
      # @return [Boolean] True if sensitive
      def self.sensitive_variable?(key)
        SENSITIVE_PATTERNS.any? { |pattern| key =~ pattern }
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
