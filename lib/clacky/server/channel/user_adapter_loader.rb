# frozen_string_literal: true

require "fileutils"

module Clacky
  module Channel
    module Adapters
      # Loads user-defined channel adapters from ~/.clacky/channels/<name>/adapter.rb.
      #
      # Each adapter file is plain Ruby that defines a subclass of
      # Clacky::Channel::Adapters::Base and self-registers via Adapters.register,
      # exactly like the bundled adapters. This loader only discovers and requires
      # those files after the built-in adapters are loaded — the existing
      # self-registration mechanism then takes over with no further wiring.
      #
      # A broken adapter (syntax error, missing interface methods) is isolated:
      # it is skipped with a logged warning and never aborts the load of others.
      module UserAdapterLoader
        DEFAULT_DIR = File.join(Clacky.data_dir, "channels")

        # Required class/instance methods a user adapter must implement to be usable.
        REQUIRED_CLASS_METHODS    = %i[platform_id platform_config].freeze
        REQUIRED_INSTANCE_METHODS = %i[start stop send_text].freeze

        Result = Struct.new(:loaded, :skipped, keyword_init: true)

        # @param dir [String] directory to scan (override for tests)
        # @return [Result] names loaded and skipped (with reasons)
        def self.load_all(dir: DEFAULT_DIR)
          result = Result.new(loaded: [], skipped: [])
          if Dir.exist?(dir)
            Dir.glob(File.join(dir, "*", "adapter.rb")).sort.each do |path|
              name = File.basename(File.dirname(path))
              load_one(path, name, result)
            end
          end
          @last_result = result
          result
        end

        # The result of the most recent load_all (set at startup). Lets `channel_verify`
        # report status without re-requiring files (require is idempotent and would
        # otherwise report already-loaded adapters as "did not register").
        def self.last_result
          @last_result || load_all
        end

        def self.load_one(path, name, result)
          before = Adapters.all.dup

          require path

          newly = Adapters.all - before
          klass = newly.last

          unless klass
            result.skipped << [name, "did not register an adapter (missing Adapters.register?)"]
            log_skip(name, result.skipped.last[1])
            return
          end

          if (missing = interface_gaps(klass)).any?
            unregister(klass)
            result.skipped << [name, "missing required methods: #{missing.join(", ")}"]
            log_skip(name, result.skipped.last[1])
            return
          end

          result.loaded << name
          Clacky::Logger.info("[UserAdapterLoader] Loaded channel adapter '#{name}' → :#{klass.platform_id}")
        rescue StandardError, ScriptError => e
          result.skipped << [name, e.message]
          log_skip(name, e.message)
        end

        def self.interface_gaps(klass)
          missing = REQUIRED_CLASS_METHODS.reject { |m| klass.respond_to?(m) }
          # Base defines stub instance methods that only raise NotImplementedError,
          # so method_defined? alone passes via inheritance. Require the subclass to
          # actually override them — i.e. the method's owner must not be Base.
          missing += REQUIRED_INSTANCE_METHODS.reject do |m|
            klass.method_defined?(m) && klass.instance_method(m).owner != Base
          end
          missing
        end

        def self.unregister(klass)
          platform = (klass.platform_id if klass.respond_to?(:platform_id))
          return unless platform

          Adapters.unregister(platform)
        end

        def self.log_skip(name, reason)
          Clacky::Logger.warn("[UserAdapterLoader] Skipped channel adapter '#{name}': #{reason}")
        end

        # Generate a ready-to-edit adapter skeleton at ~/.clacky/channels/<name>/adapter.rb.
        # The skeleton already self-registers and implements the full interface with
        # TODO markers — the author only fills in the method bodies.
        # @return [String] path to the generated adapter.rb
        def self.scaffold(name, dir: DEFAULT_DIR)
          slug = name.to_s.strip.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "")
          raise ArgumentError, "invalid channel name: #{name.inspect}" if slug.empty?

          target_dir = File.join(dir, slug)
          path = File.join(target_dir, "adapter.rb")
          raise ArgumentError, "adapter already exists: #{path}" if File.exist?(path)

          FileUtils.mkdir_p(target_dir)
          File.write(path, skeleton(slug))
          path
        end

        def self.skeleton(slug)
          const = slug.split("_").map(&:capitalize).join
          <<~RUBY
            # frozen_string_literal: true

            # User-defined channel adapter for ":#{slug}".
            # Edit the TODO sections, then it loads automatically on next start.
            # Verify with: clacky channel verify

            module Clacky
              module Channel
                module Adapters
                  class #{const}Adapter < Base
                    def self.platform_id
                      :#{slug}
                    end

                    # Map raw config (channels.yml `#{slug}` section) to a symbol-keyed hash.
                    def self.platform_config(data)
                      {
                        # TODO: pull your credentials out of `data`
                        # token: data["IM_#{slug.upcase}_TOKEN"] || data["token"]
                      }.compact
                    end

                    def initialize(config)
                      @config = config
                    end

                    # Begin receiving messages. Blocks until #stop — runs inside a Thread.
                    # Yield one standardized event Hash per inbound message.
                    def start(&on_message)
                      # TODO: connect to your platform and loop, calling on_message.call(event)
                      raise NotImplementedError
                    end

                    def stop
                      # TODO: close connections / stop the read loop
                    end

                    # Send a plain text (or Markdown) message to a chat.
                    # @return [Hash] { message_id: String }
                    def send_text(chat_id, text, reply_to: nil)
                      # TODO: call your platform's send API
                      raise NotImplementedError
                    end

                    # Optional: validate config; return array of error strings (empty = ok).
                    def validate_config(config)
                      []
                    end

                    Adapters.register(platform_id, self)
                  end
                end
              end
            end
          RUBY
        end
      end
    end
  end
end
