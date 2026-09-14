# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Clacky
  module DefaultExtensions
    module Codex
      # Creates an isolated CODEX_HOME and reuses a securely validated
      # file-backed login plus a small allowlist of safe model preferences.
      class CodexHome
        class Error < StandardError; end
        class UnsafeManagedHomeError < Error; end

        CONFIG_CONTENT = "cli_auth_credentials_store = \"auto\"\n"
        MAX_SOURCE_CONFIG_BYTES = 1_048_576
        MODEL_VALUE_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:+\/-]{0,127}\z/
        REASONING_EFFORTS = %w[none minimal low medium high xhigh max ultra].freeze
        SERVICE_TIERS = %w[auto default flex scale priority fast ultrafast].freeze
        PREFERENCE_KEYS = %w[service_tier model model_reasoning_effort].freeze
        SENSITIVE_HOME_PATHS = [
          ".clacky",
          ".ssh",
          ".aws",
          ".azure",
          ".kube",
          ".gnupg",
          ".docker/config.json",
          ".config/gcloud",
          ".config/gh",
          ".config/glab-cli",
          ".config/rclone",
          ".config/fish",
          ".cargo/credentials",
          ".cargo/credentials.toml",
          ".gem/credentials",
          ".pypirc",
          ".terraform.d",
          ".kaggle",
          ".cache/huggingface/token",
          ".huggingface",
          ".git-credentials",
          ".netrc",
          ".npmrc",
          ".profile",
          ".bash_profile",
          ".bashrc",
          ".zprofile",
          ".zshenv",
          ".zshrc"
        ].freeze

        Result = Struct.new(
          :managed_home,
          :auth_reused,
          :auth_reason,
          :protected_auth_paths,
          :protected_paths,
          keyword_init: true
        )

        def initialize(managed_home: nil, source_home: nil, source_auth_path: nil,
                       platform: RUBY_PLATFORM, current_uid: Process.uid,
                       symlink_creator: nil, stat_reader: nil,
                       managed_stat_reader: nil, managed_lstat_reader: nil,
                       source_config_opener: nil)
          @platform = platform.to_s
          @managed_home = File.expand_path(
            managed_home || default_managed_home
          )
          @source_home = File.expand_path(source_home || default_source_home)
          @source_auth_path = File.expand_path(
            source_auth_path || File.join(@source_home, "auth.json")
          )
          @current_uid = current_uid
          @symlink_creator = symlink_creator || File.method(:symlink)
          @stat_reader = stat_reader || File.method(:stat)
          @managed_uid = Process.uid
          @managed_stat_reader = managed_stat_reader || File.method(:stat)
          @managed_lstat_reader = managed_lstat_reader || File.method(:lstat)
          @source_config_opener = source_config_opener || lambda do |path, flags, &block|
            File.open(path, flags, &block)
          end
        end

        def prepare
          validate_home_separation!
          prepare_managed_parent!
          if File.symlink?(prepare_lock_path)
            raise UnsafeManagedHomeError, "managed Codex lock must not be a symlink"
          end
          File.open(prepare_lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
            lock_stat = lock.stat
            if lock_stat.uid != @managed_uid
              raise UnsafeManagedHomeError, "managed Codex lock has an unsafe owner"
            end
            FileUtils.chmod(0o600, prepare_lock_path)
            lock.flock(File::LOCK_EX)
            prepare_locked
          end
        end

        private def validate_home_separation!
          managed = canonical_home_path(@managed_home)
          source = canonical_home_path(@source_home)
          separated = managed != source &&
                      !inside_directory?(managed, source) &&
                      !inside_directory?(source, managed)
          return if separated

          raise UnsafeManagedHomeError,
                "managed and source Codex homes must be separate"
        end

        private def canonical_home_path(path)
          expanded = File.expand_path(path)
          suffix = []
          current = expanded

          until File.exist?(current)
            parent = File.dirname(current)
            break if parent == current

            suffix.unshift(File.basename(current))
            current = parent
          end

          File.expand_path(File.join(File.realpath(current), *suffix))
        rescue SystemCallError, ArgumentError
          expanded
        end

        private def prepare_locked
          prepare_managed_home!

          return without_auth_reuse("unsupported_platform") if windows?

          source_path, rejection = validated_source_auth
          return without_auth_reuse(rejection) if rejection

          destination = managed_auth_path
          if File.symlink?(destination)
            return reused_result if symlink_targets?(destination, source_path)
            begin
              File.unlink(destination)
            rescue SystemCallError
              return result(false, "managed_auth_occupied")
            end
          elsif path_entry?(destination)
            return result(false, "managed_auth_occupied")
          end

          created = false
          begin
            @symlink_creator.call(source_path, destination)
            created = true
            unless File.symlink?(destination) && symlink_targets?(destination, source_path)
              File.unlink(destination) if created && path_entry?(destination)
              return result(false, "symlink_failed")
            end
          rescue Errno::EEXIST
            return reused_result if File.symlink?(destination) &&
                                    symlink_targets?(destination, source_path)

            return result(false, "managed_auth_occupied")
          rescue NotImplementedError, SystemCallError
            File.unlink(destination) if created && File.symlink?(destination)
            return result(false, "symlink_failed")
          end

          reused_result
        end

        private def default_source_home
          configured = ENV["CODEX_HOME"].to_s.strip
          configured.empty? ? File.join(Dir.home, ".codex") : configured
        end

        private def default_managed_home
          if @platform.match?(/darwin/i)
            File.join(Dir.home, "Library", "Application Support", "OpenClacky", "codex")
          else
            data_home = ENV["XDG_DATA_HOME"].to_s.strip
            data_home = File.join(Dir.home, ".local", "share") if data_home.empty?
            File.join(data_home, "openclacky", "codex")
          end
        end

        private def prepare_managed_parent!
          parent = File.dirname(@managed_home)
          validate_managed_ancestors!(parent)
          FileUtils.mkdir_p(parent, mode: 0o700)
          validate_managed_ancestors!(parent)
        end

        private def prepare_managed_home!
          validate_managed_ancestors!(@managed_home)
          if File.symlink?(@managed_home)
            raise UnsafeManagedHomeError, "managed Codex home must not be a symlink"
          end
          if File.exist?(@managed_home) && !File.directory?(@managed_home)
            raise UnsafeManagedHomeError, "managed Codex home must be a directory"
          end

          FileUtils.mkdir_p(@managed_home, mode: 0o700)
          validate_managed_ancestors!(@managed_home)
          FileUtils.chmod(0o700, @managed_home)
          write_managed_config!
        end

        private def validate_managed_ancestors!(path)
          current = File.expand_path(path)
          loop do
            if path_entry?(current)
              if File.symlink?(current)
                link_stat = @managed_lstat_reader.call(current)
                trusted_system_link = link_stat.uid.zero? &&
                                      (link_stat.mode & 0o022).zero?
                unless trusted_system_link
                  raise UnsafeManagedHomeError,
                        "managed Codex path contains a symlinked ancestor"
                end
              end

              stat = @managed_stat_reader.call(current)
              validate_managed_path_stat!(current, stat)
            end

            parent = File.dirname(current)
            break if parent == current
            current = parent
          end
        rescue SystemCallError => e
          raise UnsafeManagedHomeError,
                "managed Codex path could not be validated: #{e.class}"
        end

        private def validate_managed_path_stat!(_path, stat)
          return unless stat.respond_to?(:uid)

          unless stat.uid == @managed_uid || stat.uid.zero?
            raise UnsafeManagedHomeError,
                  "managed Codex path has an unsafe owner"
          end

          writable = (stat.mode & 0o022) != 0
          sticky_root = stat.uid.zero? && (stat.mode & 0o1000) != 0
          return unless writable && !sticky_root

          raise UnsafeManagedHomeError,
                "managed Codex path has unsafe permissions"
        end

        private def write_managed_config!
          destination = File.join(@managed_home, "config.toml")
          if File.symlink?(destination) ||
             (File.exist?(destination) && !File.file?(destination))
            raise UnsafeManagedHomeError,
                  "managed Codex config must be a regular file"
          end

          temporary = File.join(
            @managed_home,
            ".config.toml.tmp-#{Process.pid}-#{SecureRandom.hex(8)}"
          )
          File.open(
            temporary,
            File::WRONLY | File::CREAT | File::EXCL,
            0o600
          ) do |file|
            file.write(managed_config_content)
            file.flush
            file.fsync
          end
          FileUtils.chmod(0o600, temporary)
          File.rename(temporary, destination)
          FileUtils.chmod(0o600, destination)
        ensure
          File.unlink(temporary) if temporary && path_entry?(temporary)
        end

        private def managed_config_content
          preferences = validated_source_preferences
          lines = [CONFIG_CONTENT.chomp]
          PREFERENCE_KEYS.each do |key|
            value = preferences[key]
            lines << %(#{key} = "#{value}") if value
          end
          "#{lines.join("\n")}\n"
        end

        private def validated_source_preferences
          return {} unless File.directory?(@source_home)
          return {} if File.symlink?(@source_home)

          source_home_real = File.realpath(@source_home)
          return {} if validate_source_home(source_home_real)

          source_config = File.join(@source_home, "config.toml")
          entry_stat = File.lstat(source_config)
          return {} unless entry_stat.file?

          source_real = File.realpath(source_config)
          return {} unless inside_directory?(source_real, source_home_real)

          flags = File::RDONLY
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
          flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
          @source_config_opener.call(source_config, flags) do |file|
            stat = file.stat
            return {} unless stat.file?
            return {} unless same_file?(entry_stat, stat)
            return {} if !@current_uid.nil? && stat.respond_to?(:uid) &&
                         stat.uid != @current_uid
            return {} unless (stat.mode & 0o022).zero?
            return {} if stat.size > MAX_SOURCE_CONFIG_BYTES

            file.binmode
            content = file.read(MAX_SOURCE_CONFIG_BYTES + 1) || ""
            return {} if content.bytesize > MAX_SOURCE_CONFIG_BYTES

            content.force_encoding(Encoding::UTF_8)
            return {} unless content.valid_encoding?

            return parse_source_preferences(content)
          end
          {}
        rescue SystemCallError, ArgumentError
          {}
        end

        private def parse_source_preferences(content)
          preferences = {}
          content.each_line do |raw_line|
            statement = single_line_toml_statement(raw_line)
            return {} if statement.nil?
            next if statement.empty?
            break if statement.start_with?("[")

            assignment = statement.match(/\A([^=]+?)\s*=\s*(.+)\z/)
            return {} unless assignment

            key = assignment[1].strip
            # Quoted and dotted root keys are valid TOML, but rejecting them
            # keeps this deliberately small importer from missing aliases or
            # conflicts for one of the allowlisted preference names.
            return {} unless /\A[A-Za-z0-9_-]+\z/.match?(key)
            next unless PREFERENCE_KEYS.include?(key)

            value_match = assignment[2].strip.match(
              /\A(?:"([^"\\]*)"|'([^']*)')\z/
            )
            return {} unless value_match

            value = value_match[1] || value_match[2]
            return {} if preferences.key?(key)
            return {} unless valid_preference?(key, value)

            preferences[key] = value
          end
          preferences
        end

        private def single_line_toml_statement(raw_line)
          output = +""
          quote = nil
          escaped = false
          brackets = []

          raw_line.each_char do |character|
            if quote
              output << character
              if quote == '"'
                if escaped
                  escaped = false
                elsif character == "\\"
                  escaped = true
                elsif character == quote
                  quote = nil
                end
              elsif character == quote
                quote = nil
              end
              next
            end

            case character
            when "#"
              break
            when '"', "'"
              quote = character
            when "[", "{"
              brackets << character
            when "]"
              return nil unless brackets.pop == "["
            when "}"
              return nil unless brackets.pop == "{"
            end
            output << character
          end

          return nil if quote || escaped || !brackets.empty?

          output.strip
        end

        private def same_file?(expected, actual)
          expected.dev == actual.dev && expected.ino == actual.ino
        end

        private def valid_preference?(key, value)
          case key
          when "model"
            MODEL_VALUE_PATTERN.match?(value)
          when "model_reasoning_effort"
            REASONING_EFFORTS.include?(value)
          when "service_tier"
            SERVICE_TIERS.include?(value)
          else
            false
          end
        end

        private def validated_source_auth
          return [nil, "source_home_missing"] unless File.directory?(@source_home)
          return [nil, "source_home_symlink"] if File.symlink?(@source_home)
          return [nil, "source_missing"] unless path_entry?(@source_auth_path)
          return [nil, "source_symlink"] if File.symlink?(@source_auth_path)
          return [nil, "source_not_regular"] unless File.file?(@source_auth_path)

          source_home_real = File.realpath(@source_home)
          source_home_rejection = validate_source_home(source_home_real)
          return [nil, source_home_rejection] if source_home_rejection

          source_real = File.realpath(@source_auth_path)
          unless inside_directory?(source_real, source_home_real)
            return [nil, "outside_source_home"]
          end

          stat = @stat_reader.call(source_real)
          if !@current_uid.nil? && stat.respond_to?(:uid) && stat.uid != @current_uid
            return [nil, "wrong_owner"]
          end
          return [nil, "insecure_permissions"] unless (stat.mode & 0o077).zero?

          [source_real, nil]
        rescue SystemCallError
          [nil, "source_unavailable"]
        end

        private def validate_source_home(source_home_real)
          home_stat = @stat_reader.call(source_home_real)
          if !@current_uid.nil? && home_stat.respond_to?(:uid) &&
             home_stat.uid != @current_uid
            return "wrong_owner"
          end

          current = source_home_real
          loop do
            stat = @stat_reader.call(current)
            if !@current_uid.nil? && stat.respond_to?(:uid) &&
               stat.uid != @current_uid && stat.uid != 0
              return "untrusted_source_home_owner"
            end
            return "insecure_source_home" unless (stat.mode & 0o022).zero?

            parent = File.dirname(current)
            break if parent == current
            current = parent
          end
          nil
        end

        private def inside_directory?(path, directory)
          path.start_with?(directory.chomp(File::SEPARATOR) + File::SEPARATOR)
        end

        private def windows?
          @platform.match?(/mswin|mingw|cygwin/i)
        end

        private def managed_auth_path
          File.join(@managed_home, "auth.json")
        end

        private def prepare_lock_path
          "#{@managed_home}.prepare.lock"
        end

        private def symlink_targets?(link, source)
          File.realpath(link) == File.realpath(source)
        rescue SystemCallError
          false
        end

        private def path_entry?(path)
          File.exist?(path) || File.symlink?(path)
        end

        private def without_auth_reuse(reason)
          destination = managed_auth_path
          File.unlink(destination) if File.symlink?(destination)
          result(false, reason)
        end

        private def reused_result
          result(true, "reused")
        end

        private def result(auth_reused, auth_reason)
          auth_paths = [managed_auth_path, @source_auth_path]
          if auth_reused
            begin
              auth_paths << File.realpath(@source_auth_path)
            rescue SystemCallError
              nil
            end
          end
          auth_paths = expanded_unique_paths(auth_paths)
          Result.new(
            managed_home: @managed_home,
            auth_reused: auth_reused,
            auth_reason: auth_reason,
            protected_auth_paths: auth_paths,
            protected_paths: expanded_unique_paths(
              sensitive_home_paths + [@managed_home, @source_home] + auth_paths
            )
          )
        end

        private def sensitive_home_paths
          SENSITIVE_HOME_PATHS.map { |path| File.join(Dir.home, path) }
        end

        private def expanded_unique_paths(paths)
          paths.each_with_object([]) do |path, result|
            value = path.to_s.strip
            result << File.expand_path(value) unless value.empty?
          end.uniq
        end
      end
    end
  end
end
