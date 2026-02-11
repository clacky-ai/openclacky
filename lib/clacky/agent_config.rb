# frozen_string_literal: true

require "yaml"
require "fileutils"

module Clacky
  # ClaudeCode environment variable compatibility layer
  # Provides configuration detection from ClaudeCode's environment variables
  module ClaudeCodeEnv
    # Environment variable names used by ClaudeCode
    ENV_API_KEY = "ANTHROPIC_API_KEY"
    ENV_AUTH_TOKEN = "ANTHROPIC_AUTH_TOKEN"
    ENV_BASE_URL = "ANTHROPIC_BASE_URL"

    # Default Anthropic API endpoint
    DEFAULT_BASE_URL = "https://api.anthropic.com"

    class << self
      # Check if any ClaudeCode authentication is configured
      def configured?
        !api_key.nil? && !api_key.empty?
      end

      # Get API key - prefer ANTHROPIC_API_KEY, fallback to ANTHROPIC_AUTH_TOKEN
      def api_key
        if ENV[ENV_API_KEY] && !ENV[ENV_API_KEY].empty?
          ENV[ENV_API_KEY]
        elsif ENV[ENV_AUTH_TOKEN] && !ENV[ENV_AUTH_TOKEN].empty?
          ENV[ENV_AUTH_TOKEN]
        end
      end

      # Get base URL from environment, or return default Anthropic API URL
      def base_url
        ENV[ENV_BASE_URL] && !ENV[ENV_BASE_URL].empty? ? ENV[ENV_BASE_URL] : DEFAULT_BASE_URL
      end

      # Get configuration as a hash (includes configured values)
      # Returns api_key and base_url (always available as there's a default)
      def to_h
        {
          "api_key" => api_key,
          "base_url" => base_url
        }.compact
      end
    end
  end

  class AgentConfig
    CONFIG_DIR = File.join(Dir.home, ".clacky")
    CONFIG_FILE = File.join(CONFIG_DIR, "config.yml")

    # Default model for ClaudeCode environment
    CLAUDE_DEFAULT_MODEL = "claude-sonnet-4-5"

    PERMISSION_MODES = [:auto_approve, :confirm_safes, :plan_only].freeze

    attr_accessor :permission_mode, :max_tokens, :verbose, 
                  :enable_compression, :enable_prompt_caching,
                  :models, :current_model_index

    def initialize(options = {})
      @permission_mode = validate_permission_mode(options[:permission_mode])
      @max_tokens = options[:max_tokens] || 8192
      @verbose = options[:verbose] || false
      @enable_compression = options[:enable_compression].nil? ? true : options[:enable_compression]
      # Enable prompt caching by default for cost savings
      @enable_prompt_caching = options[:enable_prompt_caching].nil? ? true : options[:enable_prompt_caching]
      
      # Models configuration
      @models = options[:models] || []
      @current_model_index = options[:current_model_index] || 0
    end

    # Load configuration from file
    def self.load(config_file = CONFIG_FILE)
      # Load from config file first
      if File.exist?(config_file)
        data = YAML.load_file(config_file)
      else
        data = nil
      end

      # Parse models from config
      models = parse_models(data)

      # If no models configured, check ClaudeCode environment variables
      if models.empty? && ClaudeCodeEnv.configured?
        models = [{
          "api_key" => ClaudeCodeEnv.api_key,
          "base_url" => ClaudeCodeEnv.base_url,
          "model" => CLAUDE_DEFAULT_MODEL,
          "anthropic_format" => true
        }]
      end

      new(models: models)
    end

    # Save configuration to file
    def save(config_file = CONFIG_FILE)
      config_dir = File.dirname(config_file)
      FileUtils.mkdir_p(config_dir)
      File.write(config_file, to_yaml)
      FileUtils.chmod(0o600, config_file)
    end

    # Convert to YAML format (top-level array)
    def to_yaml
      YAML.dump(@models)
    end

    # Check if any model is configured
    def models_configured?
      !@models.empty? && !current_model.nil?
    end

    # Get current model configuration
    def current_model
      return nil if @models.empty?
      @models[@current_model_index]
    end

    # Get model by index
    def get_model(index)
      @models[index]
    end

    # Switch to model by index
    # Returns true if switched, false if index out of range
    def switch_model(index)
      if index >= 0 && index < @models.length
        @current_model_index = index
        true
      else
        false
      end
    end

    # List all model names
    def model_names
      @models.map { |m| m["model"] }
    end

    # Get API key for current model
    def api_key
      current_model&.dig("api_key")
    end

    # Set API key for current model
    def api_key=(value)
      return unless current_model
      current_model["api_key"] = value
    end

    # Get base URL for current model
    def base_url
      current_model&.dig("base_url")
    end

    # Set base URL for current model
    def base_url=(value)
      return unless current_model
      current_model["base_url"] = value
    end

    # Get model name for current model
    def model_name
      current_model&.dig("model")
    end

    # Set model name for current model
    def model_name=(value)
      return unless current_model
      current_model["model"] = value
    end

    # Check if should use Anthropic format for current model
    def anthropic_format?
      current_model&.dig("anthropic_format") || false
    end

    # Add a new model configuration
    def add_model(model:, api_key:, base_url:, anthropic_format: false)
      @models << {
        "api_key" => api_key,
        "base_url" => base_url,
        "model" => model,
        "anthropic_format" => anthropic_format
      }
    end

    # Remove a model by index
    # Returns true if removed, false if index out of range or it's the last model
    def remove_model(index)
      # Don't allow removing the last model
      return false if @models.length <= 1
      return false if index < 0 || index >= @models.length
      
      @models.delete_at(index)
      
      # Adjust current_model_index if necessary
      if @current_model_index >= @models.length
        @current_model_index = @models.length - 1
      end
      
      true
    end

    def is_plan_only?
      @permission_mode == :plan_only
    end

    private def validate_permission_mode(mode)
      mode ||= :confirm_safes
      mode = mode.to_sym

      unless PERMISSION_MODES.include?(mode)
        raise ArgumentError, "Invalid permission mode: #{mode}. Must be one of #{PERMISSION_MODES.join(', ')}"
      end

      mode
    end

    # Parse models from config data
    # Supports new top-level array format and old formats for backward compatibility
    private_class_method def self.parse_models(data)
      models = []

      # Handle nil or empty data
      return models if data.nil?

      if data.is_a?(Array)
        # New format: top-level array of model configurations
        models = data.map do |m|
          # Convert old name-based format to new model-based format if needed
          if m["name"] && !m["model"]
            m["model"] = m["name"]
            m.delete("name")
          end
          m
        end
      elsif data.is_a?(Hash) && data["models"]
        # Old format with "models:" key
        if data["models"].is_a?(Array)
          # Array under models key
          models = data["models"].map do |m|
            # Convert old name-based format to new model-based format
            if m["name"] && !m["model"]
              m["model"] = m["name"]
              m.delete("name")
            end
            m
          end
        elsif data["models"].is_a?(Hash)
          # Hash format with tier names as keys (very old format)
          data["models"].each do |tier_name, config|
            if config.is_a?(Hash)
              model_config = {
                "api_key" => config["api_key"],
                "base_url" => config["base_url"],
                "model" => config["model_name"] || config["model"] || tier_name,
                "anthropic_format" => config["anthropic_format"] || false
              }
              models << model_config
            elsif config.is_a?(String)
              # Old-style tier with just model name
              model_config = {
                "api_key" => data["api_key"],
                "base_url" => data["base_url"],
                "model" => config,
                "anthropic_format" => data["anthropic_format"] || false
              }
              models << model_config
            end
          end
        end
      elsif data.is_a?(Hash) && data["api_key"]
        # Very old format: single model with global config
        models << {
          "api_key" => data["api_key"],
          "base_url" => data["base_url"],
          "model" => data["model"] || CLAUDE_DEFAULT_MODEL,
          "anthropic_format" => data["anthropic_format"] || false
        }
      end

      models
    end
  end
end
