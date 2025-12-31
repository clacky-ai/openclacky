# frozen_string_literal: true

require "yaml"
require "fileutils"

module Clacky
  class Config
    CONFIG_DIR = File.join(Dir.home, ".clacky")
    CONFIG_FILE = File.join(CONFIG_DIR, "config.yml")

    attr_accessor :api_key, :model, :base_url

    def initialize(data = {})
      @api_key = data["api_key"]
      @model = data["model"] || "gpt-3.5-turbo"
      @base_url = data["base_url"] || "https://api.openai.com"
    end

    def self.load(config_file = CONFIG_FILE)
      if File.exist?(config_file)
        data = YAML.load_file(config_file) || {}
        new(data)
      else
        new
      end
    end

    def save(config_file = CONFIG_FILE)
      config_dir = File.dirname(config_file)
      FileUtils.mkdir_p(config_dir)
      File.write(config_file, to_yaml)
      FileUtils.chmod(0o600, config_file)
    end

    def to_yaml
      YAML.dump({
        "api_key" => @api_key,
        "model" => @model,
        "base_url" => @base_url
      })
    end
  end
end
