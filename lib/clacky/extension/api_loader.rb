# frozen_string_literal: true

require "fileutils"

module Clacky
  # Loads HTTP API extensions from ext.yml containers into the shared
  # Clacky::ApiExtension registry, keyed by ext_id. Every ext contributes
  # at most one api unit (`contributes.api: <path>` in ext.yml), so the
  # registry key is simply the ext id.
  #
  # A broken extension (syntax error, missing base class, no routes) is
  # isolated: skipped with a logged warning, never aborts sibling loads.
  module ApiExtensionLoader
    class << self
      def load_all(reload: false)
        result = Result.new(loaded: [], skipped: [])
        Clacky::ApiExtension.reset_registry!
        handler_mtime_cache.clear

        loader_result = Clacky::ExtensionLoader.load_all
        loader_result.api.each do |unit|
          container = loader_result.containers[unit.ext_id]
          load_one(unit.ext_id, unit.spec["handler_abs"], unit.dir, container, result, reload: reload)
        end

        @last_result = result
        log_summary(result)
        result
      end

      Result = Struct.new(:loaded, :skipped, keyword_init: true)

      def last_result
        @last_result || load_all
      end

      # Per-request hot path used by the dispatcher. Re-loads the handler
      # only when its file mtime has changed since the last load.
      def ensure_fresh(ext_id)
        loader_result = Clacky::ExtensionLoader.load_all
        unit = loader_result.api.find { |u| u.ext_id == ext_id.to_s }
        return unless unit

        path = unit.spec["handler_abs"]
        current_mtime = File.mtime(path).to_f
        cache = handler_mtime_cache
        return if cache[ext_id.to_s] == current_mtime

        container = loader_result.containers[unit.ext_id]
        r = Result.new(loaded: [], skipped: [])
        load_one(unit.ext_id, path, unit.dir, container, r, reload: true)
        r.skipped.each { |(id, reason)| log_skip(id, reason) }
        cache[ext_id.to_s] = current_mtime
      rescue StandardError => e
        Clacky::Logger.warn("[ApiExtensionLoader] ensure_fresh(#{ext_id}) failed: #{e.message}")
      end

      private def handler_mtime_cache
        @handler_mtime_cache ||= {}
      end

      def load_one(ext_id, handler_path, ext_dir, container, result, reload: false)
        before = Clacky::ApiExtension.pending_subclasses.size

        existing = reload ? Clacky::ApiExtension.registry[ext_id] : nil
        existing&.reset_routes!

        # Wrapped load: each handler gets a fresh anonymous module, so two exts
        # defining the same top-level class/constant names cannot clobber each
        # other (and the `inherited` hook fires even on repeat loads).
        load(handler_path, true)

        new_subclasses = Clacky::ApiExtension.pending_subclasses[before..] || []
        klass = new_subclasses.last || existing

        unless klass
          result.skipped << [ext_id, "no Clacky::ApiExtension subclass defined in handler.rb"]
          log_skip(ext_id, result.skipped.last[1])
          return
        end

        klass.ext_id  = ext_id
        klass.ext_dir = ext_dir
        klass.meta    = (container && container[:raw]) || {}

        if klass.routes.empty?
          result.skipped << [ext_id, "no routes declared (use get/post/... DSL)"]
          log_skip(ext_id, result.skipped.last[1])
          Clacky::ApiExtension.registry.delete(ext_id)
          return
        end

        if (gap = validate_public_endpoints(klass, container))
          result.skipped << [ext_id, gap]
          log_skip(ext_id, gap)
          return
        end

        Clacky::ApiExtension.register(ext_id, klass)
        result.loaded << ext_id
        handler_mtime_cache[ext_id] = File.mtime(handler_path).to_f rescue nil
        public_count = klass.public_paths.size
        suffix = public_count > 0 ? " (#{public_count} public)" : ""
        Clacky::Logger.info("[ApiExtensionLoader] Loaded '#{ext_id}' — #{klass.routes.size} route(s)#{suffix}")
      rescue StandardError, ScriptError => e
        result.skipped << [ext_id, e.message]
        log_skip(ext_id, e.message)
      end

      private def validate_public_endpoints(klass, container)
        return nil if klass.public_paths.empty?
        return nil if container && container[:public] == true

        "uses public_endpoint but ext.yml is missing 'public: true' at top level"
      end

      private def log_skip(ext_id, reason)
        Clacky::Logger.warn("[ApiExtensionLoader] Skipped '#{ext_id}': #{reason}")
      end

      private def log_summary(result)
        return if result.loaded.empty? && result.skipped.empty?

        total_routes = result.loaded.sum { |id| Clacky::ApiExtension.registry[id]&.routes&.size || 0 }
        Clacky::Logger.info("[ApiExtensionLoader] #{result.loaded.size} extension(s), #{total_routes} route(s); #{result.skipped.size} skipped")
      end
    end
  end
end
