# frozen_string_literal: true

require "yaml"
require "fileutils"
require_relative "deepseek_web_tools"

module Clacky
  # Search provider selection, backed by ~/.clacky/search.yml.
  #
  # The built-in Parallel/DuckDuckGo/Bing chain is the default: it needs no key
  # and no configuration, so a fresh install searches the web out of the box.
  # DeepSeek's hosted web tools are opt-in — they render JS-heavy pages to
  # Markdown but bill per call, so they only run once the user picks them.
  #
  # search.yml schema:
  #   provider: tavily     — "deepseek_web" for DeepSeek's hosted
  #                          search/fetch, blank for built-in engines only,
  #                          otherwise the basename of a script in ~/.clacky/searchers/
  #   keys:                — credentials per provider, so switching providers never
  #     tavily: tvly-xxx       hands one provider's key to another (optional for
  #                            deepseek_web, which can reuse a configured model key)
  #
  # A missing file, or one without a `provider` key, means "never chosen" and
  # resolves to the free chain.
  #
  # The directory is the registry: dropping my_engine.rb into
  # ~/.clacky/searchers/ and setting `provider: my_engine` is all it takes,
  # mirroring how ~/.clacky/skills/ and ~/.clacky/parsers/ work.
  module SearchConfig
    CONFIG_PATH = File.expand_path("~/.clacky/search.yml").freeze

    # Hosted DeepSeek search + page fetch, billed per successful call upstream.
    # It behaves like a provider but ships with the gem, so it has no script.
    DEEPSEEK_WEB = "deepseek_web"

    class << self
      # @return [Hash] { "provider" => String, "keys" => { provider => String } }
      def load
        raw = File.exist?(CONFIG_PATH) ? YAML.load_file(CONFIG_PATH) : nil
        return default_config unless raw.is_a?(Hash)

        provider = raw["provider"].to_s.strip
        keys = {}
        (raw["keys"].is_a?(Hash) ? raw["keys"] : {}).each do |name, value|
          value = value.to_s.strip
          keys[name.to_s] = value unless value.empty?
        end
        # Files written before keys were split hold one key for the provider then selected.
        legacy = raw["key"].to_s.strip
        keys[provider] ||= legacy unless provider.empty? || legacy.empty?

        { "provider" => provider, "keys" => keys }
      rescue StandardError
        default_config
      end

      # The key is stored under the resulting provider; a blank key removes it.
      def save(provider: nil, key: nil)
        current = load
        new_provider = provider.nil? ? current["provider"] : provider.to_s.strip
        keys = current["keys"]
        unless key.nil? || new_provider.empty?
          key = key.to_s.strip
          if key.empty?
            keys.delete(new_provider)
          else
            keys[new_provider] = key
          end
        end

        payload = {
          "provider" => new_provider,
          "keys" => keys
        }

        FileUtils.mkdir_p(File.dirname(CONFIG_PATH))
        File.write(CONFIG_PATH, payload.to_yaml)
        File.chmod(0o600, CONFIG_PATH)

        # A new provider or key invalidates an earlier failure, so the next
        # search retries DeepSeek instead of sitting out the cooldown.
        Clacky::DeepSeekWebTools.reset_cooldown!
      end

      def deepseek_web?
        load["provider"] == DEEPSEEK_WEB
      end

      private def default_config
        { "provider" => "", "keys" => {} }
      end

      # Absolute path of the configured searcher, or nil when unset/missing.
      # A provider naming a script that isn't installed is treated as unset so
      # web_search silently falls back instead of erroring on every search.
      def script_path
        name = load["provider"]
        return nil if name.empty? || name == DEEPSEEK_WEB

        Clacky::Utils::SearcherManager.path_for(name)
      end

      def key
        config = load
        config["keys"][config["provider"]].to_s
      end

      def key_for(provider)
        load["keys"][provider.to_s].to_s
      end
    end
  end
end
