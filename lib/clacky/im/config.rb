# frozen_string_literal: true

require "fileutils"

module Clacky
  module IM
    # Configuration management for IM bridge.
    # Reads from and writes to ~/.clacky/im-bridge/config.env
    class Config
      CONFIG_DIR = File.join(Dir.home, ".clacky", "im-bridge")
      CONFIG_FILE = File.join(CONFIG_DIR, "config.env")

      attr_reader :enabled_platforms, :working_dir, :permission_mode

      def initialize(data = {})
        @data = data
        @enabled_platforms = parse_csv(data["IM_ENABLED_PLATFORMS"]) || []
        @working_dir = data["IM_WORKING_DIR"] || Dir.home
        @permission_mode = data["IM_PERMISSION_MODE"] || "auto_approve"
      end

      # Load configuration from file
      # @return [Config]
      def self.load
        return new unless File.exist?(CONFIG_FILE)

        data = parse_env_file(File.read(CONFIG_FILE))
        new(data)
      end

      # Save configuration to file
      # @return [void]
      def save
        FileUtils.mkdir_p(CONFIG_DIR)
        content = serialize_env_file

        # Write atomically with secure permissions
        tmp_file = "#{CONFIG_FILE}.tmp"
        File.write(tmp_file, content)
        File.chmod(0o600, tmp_file)
        File.rename(tmp_file, CONFIG_FILE)
      end

      # Check if configuration file exists
      # @return [Boolean]
      def self.exist?
        File.exist?(CONFIG_FILE)
      end

      # Get platform-specific configuration
      # @param platform [Symbol] Platform identifier
      # @return [Hash] Platform configuration
      def platform_config(platform)
        klass = Adapters.find(platform)
        return {} unless klass

        klass.platform_config(@data)
      end

      # Set platform configuration
      # @param platform [Symbol] Platform identifier
      # @param config [Hash] Platform configuration
      # @return [void]
      def set_platform_config(platform, config)
        klass = Adapters.find(platform)
        return unless klass

        klass.set_env_data(@data, config)
      end

      # Set enabled platforms
      # @param platforms [Array<Symbol>] Platform identifiers
      # @return [void]
      def enabled_platforms=(platforms)
        @enabled_platforms = platforms
        @data["IM_ENABLED_PLATFORMS"] = format_csv(platforms.map(&:to_s))
      end

      # Set working directory
      # @param dir [String] Working directory path
      # @return [void]
      def working_dir=(dir)
        @working_dir = dir
        @data["IM_WORKING_DIR"] = dir
      end

      # Set permission mode
      # @param mode [String] Permission mode (auto_approve, confirm_safes, confirm_all)
      # @return [void]
      def permission_mode=(mode)
        @permission_mode = mode
        @data["IM_PERMISSION_MODE"] = mode
      end

      # Mask sensitive values for display
      # @param key [String] Configuration key
      # @param value [String] Configuration value
      # @return [String] Masked value
      def self.mask_secret(key, value)
        return "" if value.nil? || value.empty?

        secret_keys = %w[SECRET TOKEN KEY PASSWORD]
        is_secret = secret_keys.any? { |k| key.upcase.include?(k) }

        if is_secret && value.length > 4
          "****#{value[-4..]}"
        else
          value
        end
      end

      private

      # Parse env file content into hash
      # @param content [String] File content
      # @return [Hash] Parsed configuration
      def self.parse_env_file(content)
        data = {}
        content.each_line do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")

          key, value = line.split("=", 2)
          next unless key && value

          key = key.strip
          value = value.strip

          # Remove surrounding quotes
          value = value[1..-2] if (value.start_with?('"') && value.end_with?('"')) ||
                                   (value.start_with?("'") && value.end_with?("'"))

          data[key] = value
        end
        data
      end

      # Serialize configuration to env file format
      # @return [String] Env file content
      def serialize_env_file
        lines = []
        lines << "# IM Bridge Configuration"
        lines << "# Generated at #{Time.now}"
        lines << ""

        lines << "# General settings"
        lines << format_env_line("IM_ENABLED_PLATFORMS", @data["IM_ENABLED_PLATFORMS"])
        lines << format_env_line("IM_WORKING_DIR", @data["IM_WORKING_DIR"])
        lines << format_env_line("IM_PERMISSION_MODE", @data["IM_PERMISSION_MODE"])
        lines << ""

        @enabled_platforms.each do |platform|
          klass = Adapters.find(platform.to_sym)
          next unless klass

          lines << "# #{platform.to_s.capitalize} configuration"
          klass.env_keys.each do |key|
            lines << format_env_line(key, @data[key])
          end
          lines << ""
        end

        lines.join("\n")
      end

      # Format a single env line
      # @param key [String] Environment variable key
      # @param value [String, nil] Environment variable value
      # @return [String] Formatted line
      def format_env_line(key, value)
        return "" if value.nil? || value.to_s.empty?
        "#{key}=#{value}"
      end

      # Parse comma-separated values
      # @param value [String, nil] CSV string
      # @return [Array<String>, nil] Parsed array
      def parse_csv(value)
        return nil if value.nil? || value.empty?
        value.split(",").map(&:strip).reject(&:empty?)
      end

      # Format array as comma-separated values
      # @param array [Array, nil] Array to format
      # @return [String, nil] CSV string
      def format_csv(array)
        return nil if array.nil? || array.empty?
        array.join(",")
      end
    end
  end
end
