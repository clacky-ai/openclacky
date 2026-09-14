# frozen_string_literal: true

require "open3"
require "json"
require "securerandom"
require "digest"

module Clacky
  module DefaultExtensions
    module Codex
      # Resolves a pinned codex-acp launch command without invoking a shell.
      class Launcher
        ADAPTER_VERSION = "1.11.0"
        ADAPTER_NAME = "@agentclientprotocol/codex-acp"
        ADAPTER_PACKAGE = "#{ADAPTER_NAME}@#{ADAPTER_VERSION}"
        CODEX_VERSION = "0.153.4"
        CODEX_NAME = "@openai/codex"
        CODEX_PACKAGE = "#{CODEX_NAME}@#{CODEX_VERSION}"
        ADAPTER_SOURCE_SHA256 = "3527bdaf90a219175c742576963e6d9e943e4ea5fbdbc3e04e7f57f9a9e11343"
        ADAPTER_BOOTSTRAP = File.expand_path("codex_acp_bootstrap.mjs", __dir__)
        BOOTSTRAP_RUN_ARG = "--openclacky-run"
        MIN_NODE_MAJOR = 20
        PACKAGED_ROOT = File.join(__dir__, "vendor")
        PERMISSION_PROFILE_PREFIX = "openclacky-protected"
        SHELL_ENV_EXCLUDE = %w[
          CODEX_HOME CODEX_CONFIG CODEX_PATH INITIAL_AGENT_MODE
          OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN
          AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
          AZURE_CLIENT_SECRET GOOGLE_APPLICATION_CREDENTIALS
          GITHUB_TOKEN GH_TOKEN NPM_TOKEN SSH_AUTH_SOCK
          NODE_OPTIONS
          HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
          http_proxy https_proxy all_proxy no_proxy
          DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
        ].freeze
        SAFE_ENV_KEYS = %w[
          PATH Path HOME USER LOGNAME SHELL LANG LANGUAGE LC_ALL
          TMPDIR TMP TEMP TZ PATHEXT SYSTEMROOT SystemRoot WINDIR COMSPEC
          SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS
          HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
          http_proxy https_proxy all_proxy no_proxy
          DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
        ].freeze

        Result = Struct.new(
          :available,
          :argv,
          :env,
          :cwd,
          :source,
          :version,
          :error_code,
          :message,
          keyword_init: true
        ) do
          def available?
            available == true
          end
        end

        def initialize(codex_home:, explicit_path: nil, codex_path: nil,
                       packaged_node: nil, packaged_entrypoint: nil,
                       path: nil, base_env: nil, version_probe: nil,
                       adapter_digest: nil, codex_package_probe: nil,
                       protected_auth_paths: [], protected_paths: [],
                       platform: RUBY_PLATFORM)
          @codex_home = File.expand_path(codex_home)
          @explicit_path = presence(explicit_path)
          @codex_path = presence(codex_path)
          @platform = platform.to_s
          @base_env = stringify_env(base_env || ENV.to_h)
          @path = path.nil? ? @base_env["PATH"].to_s : path.to_s
          @packaged_node = File.expand_path(packaged_node || default_packaged_node)
          @packaged_entrypoint = File.expand_path(
            packaged_entrypoint || File.join(
              PACKAGED_ROOT,
              "node_modules",
              "@agentclientprotocol",
              "codex-acp",
              "dist",
              "index.js"
            )
          )
          @version_probe = version_probe
          @adapter_digest = adapter_digest || lambda do |adapter_path|
            Digest::SHA256.file(File.realpath(adapter_path)).hexdigest
          end
          @codex_package_probe = codex_package_probe
          @permission_profile = "#{PERMISSION_PROFILE_PREFIX}-#{SecureRandom.hex(16)}"
          @protected_paths = normalize_protected_paths(
            [File.join(@codex_home, "auth.json")] +
              Array(protected_auth_paths) + Array(protected_paths)
          )
        end

        def resolve
          if windows?
            return failure(
              "unsupported_platform",
              "Codex ACP is not yet available on Windows in this OpenClacky preview."
            )
          end

          codex_override, codex_error = verified_codex_override
          return failure("invalid_codex_path", codex_error) if codex_error

          if @explicit_path
            explicit = verified_executable(@explicit_path)
            unless explicit
              return failure(
                "invalid_explicit_path",
                "Configured codex-acp path must be an executable file."
              )
            end
            unless verified_adapter_digest?(explicit)
              return failure(
                "unverified_explicit_path",
                "Configured codex-acp source does not match the pinned SHA-256."
              )
            end
            node = find_executable("node")
            detected_node_version = node && node_version(node)
            unless compatible_node_version?(detected_node_version)
              return failure(
                "incompatible_node",
                "The verified codex-acp adapter requires Node.js 20 or newer."
              )
            end
            return success(
              [
                node,
                ADAPTER_BOOTSTRAP,
                BOOTSTRAP_RUN_ARG,
                File.realpath(explicit)
              ],
              :explicit,
              ADAPTER_VERSION,
              codex_override
            )
          end

          if executable_file?(@packaged_node) && File.file?(@packaged_entrypoint)
            return success(
              [
                @packaged_node,
                ADAPTER_BOOTSTRAP,
                BOOTSTRAP_RUN_ARG,
                @packaged_entrypoint
              ],
              :packaged,
              ADAPTER_VERSION,
              codex_override
            )
          end

          installed = find_executable("codex-acp")
          installed_version = installed && installed_adapter_version(installed)
          installed_codex_version = installed && installed_codex_package_version(installed)
          installed_verified = installed && verified_adapter_digest?(installed)

          node = find_executable("node")
          npx = find_executable("npx")
          if node && npx
            detected_node_version = node_version(node)
            unless compatible_node_version?(detected_node_version)
              return failure(
                "incompatible_node",
                "Pinned npx fallback requires Node.js 20 or newer."
              )
            end
            return success(
              [
                npx,
                "-y",
                "--package=#{ADAPTER_PACKAGE}",
                "--package=#{CODEX_PACKAGE}",
                "--",
                File.expand_path(node),
                ADAPTER_BOOTSTRAP,
                BOOTSTRAP_RUN_ARG
              ],
              :npx,
              ADAPTER_VERSION,
              codex_override
            )
          end

          if installed
            found = installed_version || "unknown"
            codex_found = installed_codex_version || "unknown"
            if installed_version == ADAPTER_VERSION &&
               installed_codex_version == CODEX_VERSION && installed_verified
              return failure(
                "untrusted_installed_codex_acp",
                "Installed codex-acp is not automatically trusted; use the " \
                  "double-pinned npx fallback or configure an operator-trusted " \
                  "CLACKY_CODEX_ACP_PATH explicitly."
              )
            end
            return failure(
              "incompatible_codex_acp",
              "Installed codex-acp/Codex versions #{found}/#{codex_found} are incompatible; " \
                "verified versions #{ADAPTER_VERSION}/#{CODEX_VERSION} are required."
            )
          end

          failure(
            "missing_dependencies",
            "Install Node.js 20+ with npx for the double-pinned fallback, or configure an " \
              "operator-trusted CLACKY_CODEX_ACP_PATH explicitly."
          )
        end

        private def default_packaged_node
          if windows?
            File.join(PACKAGED_ROOT, "node", "node.exe")
          else
            File.join(PACKAGED_ROOT, "node", "bin", "node")
          end
        end

        private def verified_codex_override
          return [nil, nil] unless @codex_path

          verified = verified_executable(@codex_path)
          return [verified, nil] if verified

          [nil, "Configured CODEX_PATH must be an executable file."]
        end

        private def verified_executable(path)
          expanded = File.expand_path(path)
          executable_file?(expanded) ? expanded : nil
        end

        private def verified_adapter_digest?(path)
          @adapter_digest.call(path).to_s == ADAPTER_SOURCE_SHA256
        rescue StandardError
          false
        end

        private def executable_file?(path)
          File.file?(path) && File.executable?(path)
        end

        private def find_executable(name)
          executable_names(name).each do |candidate_name|
            @path.split(File::PATH_SEPARATOR).each do |directory|
              next if directory.to_s.empty?

              candidate = File.expand_path(File.join(directory, candidate_name))
              return candidate if executable_file?(candidate)
            end
          end
          nil
        end

        private def executable_names(name)
          return [name] unless windows?

          extensions = @base_env.fetch("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";")
          [name] + extensions.map { |extension| "#{name}#{extension.downcase}" }
        end

        private def installed_adapter_version(path)
          return extract_version(safe_probe(path)) if @version_probe

          package_metadata_version(path)
        end

        private def node_version(path)
          output = @version_probe ? safe_probe(path) : probe_command_version(path)
          extract_version(output)
        end

        private def compatible_node_version?(version)
          version && version.to_s.split(".").first.to_i >= MIN_NODE_MAJOR
        end

        private def safe_probe(path)
          @version_probe && @version_probe.call(path)
        rescue StandardError
          nil
        end

        private def probe_command_version(path)
          stdout, _stderr, status = Open3.capture3(
            sanitized_environment(nil),
            path,
            "--version",
            unsetenv_others: true
          )
          status.success? ? stdout.to_s : nil
        rescue SystemCallError
          nil
        end

        private def package_metadata_version(executable)
          directory = File.dirname(File.realpath(executable))
          8.times do
            package_file = File.join(directory, "package.json")
            if File.file?(package_file)
              metadata = JSON.parse(File.read(package_file))
              if metadata["name"] == ADAPTER_NAME
                return extract_version(metadata["version"])
              end
            end

            parent = File.dirname(directory)
            break if parent == directory

            directory = parent
          end
          nil
        rescue JSON::ParserError, SystemCallError
          nil
        end

        private def installed_codex_package_version(adapter_path)
          if @codex_package_probe
            return extract_version(@codex_package_probe.call(adapter_path))
          end

          directory = File.dirname(File.realpath(adapter_path))
          12.times do
            package_file = File.join(
              directory, "node_modules", "@openai", "codex", "package.json"
            )
            if File.file?(package_file)
              metadata = JSON.parse(File.read(package_file))
              if metadata["name"] == CODEX_NAME
                return extract_version(metadata["version"])
              end
            end

            parent = File.dirname(directory)
            break if parent == directory
            directory = parent
          end
          nil
        rescue StandardError
          nil
        end

        private def extract_version(output)
          match = output.to_s.match(/(?:^|[^\d])(\d+\.\d+\.\d+)(?![\d.+-])/)
          match && match[1]
        end

        private def success(argv, source, version, codex_override)
          Result.new(
            available: true,
            argv: argv,
            env: sanitized_environment(codex_override, source: source),
            cwd: @codex_home,
            source: source,
            version: version
          )
        end

        private def failure(error_code, message)
          Result.new(
            available: false,
            env: sanitized_environment(nil),
            cwd: @codex_home,
            error_code: error_code,
            message: message
          )
        end

        private def sanitized_environment(codex_override, source: nil)
          env = @base_env.each_with_object({}) do |(key, value), result|
            next unless SAFE_ENV_KEYS.include?(key) || key.start_with?("LC_")

            result[key] = value
          end
          env["CODEX_HOME"] = @codex_home
          env["CODEX_CONFIG"] = JSON.generate(protected_configuration)
          env["INITIAL_AGENT_MODE"] = "read-only"
          env["CODEX_PATH"] = codex_override if codex_override
          if source == :npx
            env["NPM_CONFIG_USERCONFIG"] = File::NULL
            env["NPM_CONFIG_REGISTRY"] = "https://registry.npmjs.org/"
            env["NPM_CONFIG_IGNORE_SCRIPTS"] = "true"
            env["NPM_CONFIG_AUDIT"] = "false"
            env["NPM_CONFIG_FUND"] = "false"
          end
          env
        end

        private def protected_configuration
          filesystem = @protected_paths.each_with_object({}) do |path, result|
            result[path] = "deny"
          end
          {
            "allow_login_shell" => false,
            "default_permissions" => @permission_profile,
            "permissions" => {
              @permission_profile => {
                "extends" => ":workspace",
                "filesystem" => filesystem
              }
            },
            "shell_environment_policy" => {
              "exclude" => SHELL_ENV_EXCLUDE
            }
          }
        end

        private def normalize_protected_paths(paths)
          paths.each_with_object([]) do |path, result|
            value = path.to_s.strip
            result << File.expand_path(value) unless value.empty?
          end.uniq
        end

        private def stringify_env(env)
          env.each_with_object({}) do |(key, value), result|
            result[key.to_s] = value.to_s
          end
        end

        private def presence(value)
          string = value.to_s.strip
          string.empty? ? nil : string
        end

        private def windows?
          @platform.match?(/mswin|mingw|cygwin/i)
        end
      end
    end
  end
end
