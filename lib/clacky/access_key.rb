# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Clacky
  # Access key for server-mode authentication.
  #
  # Two sources, in priority order:
  #   1. ~/.clacky/access_key — a file holding the raw key, writable from
  #      outside the process (e.g. a sandbox host pushing a key into a
  #      pre-started container). This is what makes rotation possible:
  #      ENV is a boot-time snapshot the running process can never change.
  #   2. CLACKY_ACCESS_KEY env var — the original bootstrap mechanism.
  module AccessKey
    ENV_VAR = "CLACKY_ACCESS_KEY"

    def self.resolve
      from_file || from_env
    end

    def self.from_file
      return nil unless File.exist?(key_file)

      key = File.read(key_file).strip
      key.empty? ? nil : key
    rescue StandardError
      nil
    end

    def self.from_env
      key = ENV.fetch(ENV_VAR, "").strip
      key.empty? ? nil : key
    end

    def self.write(key)
      key = key.to_s.strip
      raise ArgumentError, "access key must not be blank" if key.empty?

      FileUtils.mkdir_p(File.dirname(key_file))
      File.write(key_file, "#{key}\n")
      FileUtils.chmod(0o600, key_file)
      key
    end

    def self.generate
      SecureRandom.hex(32)
    end

    def self.configured?
      !resolve.nil?
    end

    # Resolved lazily so specs that stub Dir.home in a before-hook still work.
    def self.key_file
      File.join(Dir.home, ".clacky", "access_key")
    end
  end
end
