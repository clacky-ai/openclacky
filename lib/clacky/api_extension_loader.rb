# frozen_string_literal: true

require "fileutils"

module Clacky
  # Discovers and loads user-defined HTTP API extensions from
  # ~/.clacky/api_ext/<name>/handler.rb. Each handler is expected to define a
  # subclass of Clacky::ApiExtension; the subclass is auto-registered with the
  # framework and its routes become available under /api/ext/<name>/.
  #
  # A broken extension (syntax error, missing base class, route conflict) is
  # isolated: skipped with a logged warning, never aborts the load of others.
  module ApiExtensionLoader
    DEFAULT_DIR  = File.expand_path("~/.clacky/api_ext")
    DISABLED_DIR = "_disabled"

    Result = Struct.new(:loaded, :skipped, keyword_init: true)

    class << self
      def load_all(dir: DEFAULT_DIR)
        result = Result.new(loaded: [], skipped: [])
        Clacky::ApiExtension.reset_registry!

        if Dir.exist?(dir)
          Dir.glob(File.join(dir, "*", "handler.rb")).sort.each do |handler_path|
            ext_dir = File.dirname(handler_path)
            ext_id  = File.basename(ext_dir)
            next if ext_id == DISABLED_DIR || ext_id.start_with?("_")
            load_one(ext_id, ext_dir, handler_path, result)
          end
        end

        @last_result = result
        log_summary(result)
        result
      end

      def last_result
        @last_result || load_all
      end

      def load_one(ext_id, ext_dir, handler_path, result)
        meta = read_meta(ext_dir)
        before = Clacky::ApiExtension.pending_subclasses.size

        require handler_path

        new_subclasses = Clacky::ApiExtension.pending_subclasses[before..] || []
        klass = new_subclasses.last

        unless klass
          result.skipped << [ext_id, "no Clacky::ApiExtension subclass defined in handler.rb"]
          log_skip(ext_id, result.skipped.last[1])
          return
        end

        klass.ext_id  = ext_id
        klass.ext_dir = ext_dir
        klass.meta    = meta

        if klass.routes.empty?
          result.skipped << [ext_id, "no routes declared (use get/post/... DSL)"]
          log_skip(ext_id, result.skipped.last[1])
          Clacky::ApiExtension.registry.delete(ext_id)
          return
        end

        if (gap = validate_public_endpoints(klass, meta))
          result.skipped << [ext_id, gap]
          log_skip(ext_id, gap)
          return
        end

        Clacky::ApiExtension.register(ext_id, klass)
        result.loaded << ext_id
        public_count = klass.public_paths.size
        suffix = public_count > 0 ? " (#{public_count} public)" : ""
        Clacky::Logger.info("[ApiExtensionLoader] Loaded '#{ext_id}' — #{klass.routes.size} route(s)#{suffix}")
      rescue StandardError, ScriptError => e
        result.skipped << [ext_id, e.message]
        log_skip(ext_id, e.message)
      end

      private def read_meta(ext_dir)
        path = File.join(ext_dir, "meta.yml")
        return {} unless File.exist?(path)

        YAMLCompat.load_file(path) || {}
      rescue StandardError => e
        Clacky::Logger.warn("[ApiExtensionLoader] Failed to read meta.yml in #{ext_dir}: #{e.message}")
        {}
      end

      private def validate_public_endpoints(klass, meta)
        return nil if klass.public_paths.empty?
        return nil if meta["public"] == true

        "uses public_endpoint but meta.yml is missing 'public: true'"
      end

      private def log_skip(ext_id, reason)
        Clacky::Logger.warn("[ApiExtensionLoader] Skipped '#{ext_id}': #{reason}")
      end

      private def log_summary(result)
        return if result.loaded.empty? && result.skipped.empty?

        total_routes = result.loaded.sum { |id| Clacky::ApiExtension.registry[id]&.routes&.size || 0 }
        Clacky::Logger.info("[ApiExtensionLoader] #{result.loaded.size} extension(s), #{total_routes} route(s); #{result.skipped.size} skipped")
      end

      # Generate a starter handler.rb at ~/.clacky/api_ext/<name>/handler.rb.
      # Returns the path to the generated file.
      def scaffold(name, dir: DEFAULT_DIR)
        slug = name.to_s.strip.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/\A-+|-+\z/, "")
        raise ArgumentError, "invalid api_ext name: #{name.inspect}" if slug.empty?

        target_dir = File.join(dir, slug)
        path = File.join(target_dir, "handler.rb")
        raise ArgumentError, "api_ext already exists: #{path}" if File.exist?(path)

        FileUtils.mkdir_p(target_dir)
        File.write(path, skeleton(slug))
        path
      end

      private def skeleton(slug)
        const = slug.split(/[-_]/).map(&:capitalize).join + "Ext"
        <<~RUBY
          # frozen_string_literal: true

          # Custom HTTP API extension mounted at /api/ext/#{slug}/
          # Scaffolded by `clacky api_ext_new #{slug}` — fill in the routes you need.
          class #{const} < Clacky::ApiExtension
            get "/hello" do
              json(message: "hello from #{slug}")
            end

            # Examples — uncomment and adapt:
            #
            # post "/items" do
            #   body = json_body
            #   error!("name required", status: 422) unless body["name"]
            #   File.write(data_path("items.json"), body.to_json)
            #   json(ok: true)
            # end
            #
            # get "/items/:id" do
            #   json(id: params[:id])
            # end
          end
        RUBY
      end
    end
  end
end
