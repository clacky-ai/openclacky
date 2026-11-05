# frozen_string_literal: true

require "yaml"
require "fileutils"
require "json"

module Clacky
  # ChannelConfig manages IM platform credentials (Feishu, WeCom, etc.).
  #
  # Config is stored in ~/.clacky/channels.yml. Every platform holds a list of
  # instances, so one platform can be connected more than once (e.g. a personal
  # and a work Feishu app):
  #
  #   channels:
  #     feishu:
  #       - id: default
  #         name: Personal
  #         enabled: true
  #         app_id: cli_xxx
  #         app_secret: xxx
  #       - id: work
  #         name: Company
  #         enabled: true
  #         app_id: cli_yyy
  #         app_secret: yyy
  #     wecom:
  #       - id: default
  #         enabled: false
  #         bot_id: xxx
  #         secret: xxx
  #
  # The legacy single-hash form (`feishu: { enabled: true, ... }`) is migrated
  # in memory on load: it becomes one instance with id "default".
  #
  # This class is only responsible for platform credentials.
  # working_dir and permission_mode live in AgentConfig.
  class ChannelConfig
    CONFIG_DIR  = File.join(Dir.home, ".clacky")
    CONFIG_FILE = File.join(CONFIG_DIR, "channels.yml")

    DEFAULT_INSTANCE_ID = "default"

    META_KEYS = %w[id name enabled].freeze

    # @param channels [Hash<String, Array<Hash>|Hash>] platform configs (raw from
    #   YAML; a Hash value is treated as a legacy single-instance config)
    # @param status_messages [Boolean] global toggle for process-status messages
    #   ("Thinking...", "Done" summary) sent to IM chats
    # @param process_messages [Boolean] global toggle for tool-process messages
    #   (interim narration, file/shell previews) sent to IM chats
    # @param progress_cards [Boolean] global toggle for live-updating progress
    #   cards on platforms that support them
    def initialize(channels: {}, status_messages: false, process_messages: false, progress_cards: true)
      @channels         = normalize_channels(channels || {})
      @status_messages  = status_messages == true ? true : false
      @process_messages = process_messages == true ? true : false
      # Opt-out (unlike the toggles above): missing key keeps cards on for existing users.
      @progress_cards   = progress_cards == false ? false : true
    end

    # Load from disk. Returns an empty instance if the file does not exist.
    # @param config_file [String]
    # @return [ChannelConfig]
    def self.load(config_file = CONFIG_FILE)
      if File.exist?(config_file)
        data = YAMLCompat.safe_load(File.read(config_file), permitted_classes: [Symbol]) || {}
      else
        data = {}
      end

      new(channels: data["channels"] || {}, status_messages: data["status_messages"], process_messages: data["process_messages"], progress_cards: data["progress_cards"])
    end

    # Persist to disk.
    # @param config_file [String]
    def save(config_file = CONFIG_FILE)
      FileUtils.mkdir_p(File.dirname(config_file))
      File.write(config_file, to_yaml)
      FileUtils.chmod(0o600, config_file)
    end

    # Serialize to YAML string.
    # @return [String]
    def to_yaml
      YAML.dump({ "status_messages" => @status_messages, "process_messages" => @process_messages, "progress_cards" => @progress_cards, "channels" => @channels })
    end

    # Returns true if at least one instance of any platform is enabled.
    def any_enabled?
      @channels.any? { |_, list| list.any? { |inst| inst["enabled"] } }
    end

    # Returns the list of platform symbols that have at least one enabled instance.
    # @return [Array<Symbol>]
    def enabled_platforms
      enabled_instances.map { |platform, _| platform }.uniq
    end

    # All enabled instances as [platform_symbol, instance_hash] pairs.
    # @return [Array<Array(Symbol, Hash)>]
    def enabled_instances
      result = []
      @channels.each do |platform, list|
        list.each do |inst|
          result << [platform.to_sym, inst] if inst["enabled"]
        end
      end
      result
    end

    # Returns true if the platform (or one specific instance) is configured and
    # enabled.
    # @param platform [Symbol, String]
    # @param instance_id [String, nil] nil means "any instance of this platform"
    def enabled?(platform, instance_id = nil)
      list = instances(platform)
      return false if list.empty?

      if instance_id.nil? || instance_id.to_s.empty?
        list.any? { |inst| inst["enabled"] }
      else
        inst = instance(platform, instance_id)
        !!(inst && inst["enabled"])
      end
    end

    # Configured instances for a platform.
    # @param platform [Symbol, String]
    # @return [Array<Hash>] string-keyed instance hashes
    def instances(platform)
      @channels[platform.to_s] || []
    end

    # Look up one instance. A nil/blank id resolves to the first instance,
    # which keeps legacy single-instance callers working unchanged.
    # @param platform [Symbol, String]
    # @param instance_id [String, nil]
    # @return [Hash, nil]
    def instance(platform, instance_id = nil)
      list = instances(platform)
      return nil if list.empty?
      return list.first if instance_id.nil? || instance_id.to_s.empty?

      list.find { |inst| inst["id"] == instance_id.to_s }
    end

    # @return [Array<String>] instance ids for a platform
    def instance_ids(platform)
      instances(platform).map { |inst| inst["id"] }
    end

    # Return the symbol-keyed config hash expected by each adapter's initializer.
    # Returns nil if the platform/instance is not configured.
    #
    # @param platform [Symbol, String]
    # @param instance_id [String, nil] nil resolves to the first instance
    # @return [Hash, nil]
    def platform_config(platform, instance_id = nil)
      raw = instance(platform, instance_id)
      return nil unless raw

      case platform.to_sym
      when :feishu
        {
          app_id:        raw["app_id"],
          app_secret:    raw["app_secret"],
          domain:        raw["domain"],
          allowed_users: raw["allowed_users"]
        }.compact
      when :wecom
        {
          bot_id: raw["bot_id"],
          secret: raw["secret"]
        }.compact
      when :weixin
        {
          token:         raw["token"],
          base_url:      raw["base_url"],
          allowed_users: raw["allowed_users"]
        }.compact
      when :discord
        {
          bot_token:     raw["bot_token"]
        }.compact
      when :dingtalk
        {
          client_id:     raw["client_id"],
          client_secret: raw["client_secret"],
          allowed_users: raw["allowed_users"]
        }.compact
      when :telegram
        {
          bot_token:     raw["bot_token"],
          base_url:      raw["base_url"],
          parse_mode:    raw.key?("parse_mode") ? raw["parse_mode"] : "Markdown",
          allowed_users: raw["allowed_users"]
        }.compact
      when :qq
        {
          app_id:        raw["app_id"],
          app_secret:    raw["app_secret"],
          base_url:      raw["base_url"],
          sandbox:       raw.key?("sandbox") ? raw["sandbox"] : nil,
          intents:       raw["intents"],
          allowed_users: raw["allowed_users"]
        }.compact
      else
        # Unknown platform — pass all non-meta keys as symbol-keyed hash
        raw.reject { |k, _| META_KEYS.include?(k) }
           .transform_keys(&:to_sym)
      end
    end

    # Set or update an instance's credentials.
    # Merges provided fields into the existing entry; creates a new instance
    # when the id does not exist yet.
    # Automatically sets enabled: true unless explicitly provided.
    #
    # @param platform [Symbol, String]
    # @param instance_id [String, nil] nil updates the first instance (creating
    #   the default one when the platform has none)
    # @param name [String, nil] display name for this instance
    # @param enabled [Boolean, nil] leave untouched when nil
    # @param fields [Hash] symbol-keyed credential fields
    # @return [String] the instance id that was written
    def set_platform(platform, instance_id: nil, name: nil, enabled: nil, **fields)
      key  = platform.to_s
      inst = instance(key, instance_id)

      if inst.nil?
        inst = { "id" => instance_id.to_s.empty? ? next_instance_id(key) : instance_id.to_s }
        @channels[key] ||= []
        @channels[key] << inst
      end

      fields.each do |k, v|
        k = k.to_s
        next if META_KEYS.include?(k)
        inst[k] = v
      end
      inst["name"] = name unless name.nil?
      inst["enabled"] = enabled unless enabled.nil?
      inst["enabled"] = true if enabled.nil? && !inst.key?("enabled")
      inst["id"]
    end

    # Global toggle: whether process-status messages ("Thinking...", "Done"
    # summary) are sent to IM chats. Defaults to false.
    def status_messages_enabled?
      @status_messages == true
    end

    # Enable/disable process-status messages globally.
    # @param enabled [Boolean]
    def set_status_messages(enabled)
      @status_messages = enabled ? true : false
    end

    # Global toggle: whether tool-process messages (interim narration,
    # file/shell previews) are sent to IM chats. Defaults to false.
    def process_messages_enabled?
      @process_messages == true
    end

    # Enable/disable tool-process messages globally.
    # @param enabled [Boolean]
    def set_process_messages(enabled)
      @process_messages = enabled ? true : false
    end

    # Global toggle: whether task progress is shown in one live-updating card
    # on platforms that support it. When off, status and process updates are
    # sent as separate messages instead. Defaults to true.
    def progress_cards_enabled?
      @progress_cards == true
    end

    # Enable/disable progress cards globally.
    # @param enabled [Boolean]
    def set_progress_cards(enabled)
      @progress_cards = enabled ? true : false
    end

    # Enable an instance (requires it to already be configured).
    # @param platform [Symbol, String]
    # @param instance_id [String, nil] nil enables the first instance
    # @raise [ArgumentError] if the instance has no stored credentials yet.
    def enable_platform(platform, instance_id = nil)
      inst = instance(platform, instance_id)
      raise ArgumentError, "Platform #{platform} is not configured" unless inst
      inst["enabled"] = true
    end

    # Disable an instance (keeps credentials, just sets enabled: false).
    # Without an id, every instance of the platform is disabled.
    # @param platform [Symbol, String]
    # @param instance_id [String, nil]
    def disable_platform(platform, instance_id = nil)
      targets = if instance_id.nil? || instance_id.to_s.empty?
        instances(platform)
      else
        [instance(platform, instance_id)].compact
      end
      targets.each { |inst| inst["enabled"] = false }
    end

    # Remove an instance entirely. Without an id, the whole platform entry is
    # removed.
    # @param platform [Symbol, String]
    # @param instance_id [String, nil]
    # @return [Boolean] true when something was removed
    def remove_platform(platform, instance_id = nil)
      key = platform.to_s
      return false unless @channels.key?(key)

      if instance_id.nil? || instance_id.to_s.empty?
        @channels.delete(key)
        return true
      end

      list = @channels[key]
      removed = list.reject! { |inst| inst["id"] == instance_id.to_s }
      @channels.delete(key) if list.empty?
      !removed.nil?
    end

    # Deep copy - prevents callers from mutating shared config state.
    # @return [ChannelConfig]
    def deep_copy
      self.class.new(channels: JSON.parse(JSON.generate(@channels)), status_messages: @status_messages, process_messages: @process_messages, progress_cards: @progress_cards)
    end

    private def normalize_channels(raw)
      result = {}
      raw.each do |platform, value|
        result[platform.to_s] = normalize_instances(platform.to_s, value)
      end
      result
    end

    private def normalize_instances(platform, value)
      list = case value
             when Array then value
             when Hash  then [value]
             else []
             end

      used_ids = []
      list.each_with_index.map do |item, index|
        inst = (item || {}).each_with_object({}) { |(k, v), out| out[k.to_s] = v }
        id = inst["id"].to_s
        id = index.zero? ? DEFAULT_INSTANCE_ID : "#{platform}-#{index + 1}" if id.empty?
        id = "#{id}-#{index + 1}" while used_ids.include?(id)
        used_ids << id
        inst["id"] = id
        inst["enabled"] = false unless inst.key?("enabled")
        inst
      end
    end

    private def next_instance_id(platform)
      list = instances(platform)
      return DEFAULT_INSTANCE_ID if list.empty?

      used = list.map { |inst| inst["id"] }
      index = list.length + 1
      index += 1 while used.include?("#{platform}-#{index}")
      "#{platform}-#{index}"
    end
  end
end
