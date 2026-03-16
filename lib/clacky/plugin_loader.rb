# frozen_string_literal: true

require "yaml"
require "fileutils"
require "json"

module Clacky
  # PluginLoader scans ~/.clacky/plugins/ and loads installed plugins.
  #
  # Plugin directory structure:
  #   ~/.clacky/plugins/
  #   └── <plugin-name>/
  #       ├── plugin.yml    ← required: metadata (name, version, author, etc.)
  #       ├── sidebar.html  ← optional: sidebar nav entry HTML fragment
  #       ├── panel.html    ← optional: main panel HTML fragment
  #       └── plugin.js     ← optional: plugin JavaScript logic
  #
  # plugin.yml schema:
  #   id: "coding-agent"
  #   name: "Coding Agent"         # string OR {en: "...", zh: "..."}
  #   version: "0.1.0"
  #   author: "Your Name"
  #   description: "..."           # string OR {en: "...", zh: "..."}
  #   icon: "💻"                   ← emoji or URL
  #   sidebar: true                ← whether to inject a sidebar entry (default: true)
  #   sidebar_divider: "Projects"  # optional; string OR {en: "...", zh: "..."}
  #
  # Plugins are loaded at server startup and served via GET /api/plugins.
  # The frontend dynamically injects sidebar entries and panels on boot.
  class PluginLoader
    PLUGINS_DIR = File.join(Dir.home, ".clacky", "plugins")

    def initialize(plugins_dir = PLUGINS_DIR)
      @plugins_dir = plugins_dir
    end

    # Scan the plugins directory and return a list of loaded plugin descriptors.
    # Each descriptor is a Hash ready to be serialized as JSON.
    # Plugins with missing or invalid plugin.yml are silently skipped.
    def load_all
      return [] unless Dir.exist?(@plugins_dir)

      Dir.entries(@plugins_dir)
         .select { |entry| plugin_dir?(entry) }
         .map    { |entry| load_plugin(entry) }
         .compact
    end

    private

    # Check if an entry is a valid plugin directory (not . or ..)
    private def plugin_dir?(entry)
      return false if entry.start_with?(".")

      dir_path = File.join(@plugins_dir, entry)
      Dir.exist?(dir_path)
    end

    # Load a single plugin from its directory. Returns nil if invalid.
    private def load_plugin(dir_name)
      dir_path    = File.join(@plugins_dir, dir_name)
      config_path = File.join(dir_path, "plugin.yml")

      return nil unless File.exist?(config_path)

      config = YAML.safe_load(File.read(config_path)) || {}
      return nil unless config.is_a?(Hash)

      # Build the plugin descriptor.
      # name / description / sidebar_divider support two formats:
      #   - String (legacy):     "Coding Agent"
      #   - Hash (i18n):         { "en" => "Coding Agent", "zh" => "编程助手" }
      # The hash is passed through as-is; the frontend resolves the active language.
      plugin = {
        id:              config["id"]              || dir_name,
        name:            config["name"]            || dir_name,
        version:         config["version"]         || "0.0.1",
        author:          config["author"]          || "",
        description:     config["description"]     || "",
        icon:            config["icon"]            || "🧩",
        sidebar:         config.fetch("sidebar", true),
        sidebar_divider: config["sidebar_divider"] || nil,
        dir:             dir_path,
        # Flags indicating which optional asset files are present
        has_sidebar_html: File.exist?(File.join(dir_path, "sidebar.html")),
        has_panel_html:   File.exist?(File.join(dir_path, "panel.html")),
        has_plugin_js:    File.exist?(File.join(dir_path, "plugin.js")),
      }

      plugin
    rescue StandardError => e
      warn "[PluginLoader] Failed to load plugin '#{dir_name}': #{e.message}"
      nil
    end

    # Read an asset file from a plugin directory. Returns nil if missing.
    public def read_asset(plugin_id, filename)
      path = File.join(@plugins_dir, plugin_id, filename)
      return nil unless File.exist?(path)

      File.read(path)
    rescue StandardError
      nil
    end
  end
end
