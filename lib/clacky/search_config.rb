# frozen_string_literal: true

require "yaml"
require "fileutils"

module Clacky
  # Search provider selection, backed by ~/.clacky/search.yml.
  #
  # The built-in DuckDuckGo/Bing scrapers need no configuration and stay the
  # default. Pointing `provider` at a script in ~/.clacky/searchers/ routes
  # web_search through an API-backed engine instead, which is what users who
  # want higher-quality results (or China-reachable ones) reach for.
  #
  # search.yml schema:
  #   provider: tavily     — basename of a script in ~/.clacky/searchers/;
  #                          blank or missing means built-in engines only
  #   key: tvly-xxx        — credential handed to that script via env
  #
  # The directory is the registry: dropping my_engine.rb into
  # ~/.clacky/searchers/ and setting `provider: my_engine` is all it takes,
  # mirroring how ~/.clacky/skills/ and ~/.clacky/parsers/ work.
  module SearchConfig
    CONFIG_PATH = File.expand_path("~/.clacky/search.yml").freeze

    class << self
      # @return [Hash] { "provider" => String, "key" => String }
      def load
        raw = File.exist?(CONFIG_PATH) ? YAML.load_file(CONFIG_PATH) : nil
        return { "provider" => "", "key" => "" } unless raw.is_a?(Hash)

        { "provider" => raw["provider"].to_s.strip, "key" => raw["key"].to_s.strip }
      rescue StandardError
        { "provider" => "", "key" => "" }
      end

      def save(provider:, key:)
        FileUtils.mkdir_p(File.dirname(CONFIG_PATH))
        File.write(CONFIG_PATH, { "provider" => provider.to_s.strip, "key" => key.to_s.strip }.to_yaml)
        File.chmod(0o600, CONFIG_PATH)
      end

      # Absolute path of the configured searcher, or nil when unset/missing.
      # A provider naming a script that isn't installed is treated as unset so
      # web_search silently falls back instead of erroring on every search.
      def script_path
        name = load["provider"]
        return nil if name.empty?

        Clacky::Utils::SearcherManager.path_for(name)
      end

      def key
        load["key"]
      end
    end
  end
end
