# frozen_string_literal: true

module Clacky
  # Loads Ruby hook files contributed by ext.yml containers
  # (`contributes.hooks: [{ event, file }]`). Each file is required once at
  # process start; it registers callbacks via `Clacky::ExtensionHookRegistry.add`.
  # Every agent then copies those callbacks onto its own `HookManager` during
  # init, so each agent gets its own isolated hook chain.
  module ExtensionHookLoader
    Result = Struct.new(:registered, :skipped, keyword_init: true)

    def self.load_all
      result = Result.new(registered: [], skipped: [])
      units = Array(Clacky::ExtensionLoader.last_result&.hooks)
      units.each do |unit|
        event = unit.spec["event"].to_sym
        unless Clacky::HookManager::HOOK_EVENTS.include?(event)
          msg = "unknown event: #{event}"
          result.skipped << [unit.id, msg]
          Clacky::Logger.warn("[ExtensionHookLoader] #{unit.ext_id}/#{unit.id}: #{msg}")
          next
        end

        Clacky::ExtensionHookRegistry.current_event = event
        require unit.spec["file_abs"]
        result.registered << [unit.ext_id, unit.id, event]
        Clacky::Logger.info("[ExtensionHookLoader] registered",
                            ext: unit.ext_id, id: unit.id, event: event)
      rescue StandardError, ScriptError => e
        result.skipped << [unit.id, e.message]
        Clacky::Logger.warn("[ExtensionHookLoader] #{unit.ext_id}/#{unit.id}: #{e.message}")
      ensure
        Clacky::ExtensionHookRegistry.current_event = nil
      end
      @last_result = result
      result
    end

    def self.last_result
      @last_result || load_all
    end
  end

  # Process-wide registry for ext-contributed hook callbacks. Callbacks are
  # registered once at file load time; each new agent copies them onto its own
  # HookManager during init via `apply_to`.
  module ExtensionHookRegistry
    @callbacks = Hash.new { |h, k| h[k] = [] }
    @current_event = nil

    class << self
      attr_accessor :current_event

      # Register a callback. `event` falls back to the loader-set context so
      # ext hook files can call `add { ... }` without repeating the event name
      # already declared in ext.yml.
      def add(event = nil, &block)
        ev = (event || @current_event)
        raise ArgumentError, "ExtensionHookRegistry.add called outside a hook file" unless ev

        @callbacks[ev.to_sym] << block
      end

      def callbacks
        @callbacks
      end

      def apply_to(hook_manager)
        @callbacks.each do |event, blocks|
          blocks.each { |b| hook_manager.add(event, &b) }
        end
      end

      def clear!
        @callbacks.clear
      end
    end
  end
end
