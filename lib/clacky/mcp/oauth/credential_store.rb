# frozen_string_literal: true

require "json"
require "fileutils"

module Clacky
  module Mcp
    module OAuth
      class CredentialStore
        class Error < StandardError; end

        attr_reader :path

        def initialize(server_name:, home: Dir.home)
          safe_name = server_name.to_s.gsub(/[^a-zA-Z0-9_.-]/, "_")
          safe_name = "server" if safe_name.empty?
          @path = File.join(File.expand_path(home), ".clacky", "mcp", "oauth", "#{safe_name}.json")
        end

        def load
          return nil unless File.file?(@path)

          with_lock(File::LOCK_SH) do
            value = JSON.parse(File.read(@path))
            raise JSON::ParserError unless value.is_a?(Hash)
            value
          end
        rescue JSON::ParserError
          raise Error, "invalid OAuth credential file; log in again"
        end

        def save(value)
          ensure_directory
          with_lock(File::LOCK_EX) do
            temporary = "#{@path}.tmp-#{Process.pid}-#{rand(1_000_000)}"
            File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
              file.write(JSON.generate(value))
              file.write("\n")
              file.flush
              file.fsync
            end
            File.rename(temporary, @path)
            File.chmod(0o600, @path)
          ensure
            FileUtils.rm_f(temporary) if defined?(temporary) && temporary
          end
          value
        end

        def delete
          return unless File.exist?(@path)

          ensure_directory
          with_lock(File::LOCK_EX) { FileUtils.rm_f(@path) }
        end

        def inspect
          "#<#{self.class} path=#{@path.inspect}>"
        end

        private def ensure_directory
          FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
          File.chmod(0o700, File.dirname(@path))
        end

        private def with_lock(mode)
          ensure_directory
          lock_path = "#{@path}.lock"
          File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(mode)
            yield
          ensure
            lock.flock(File::LOCK_UN) rescue nil
          end
        end
      end
    end
  end
end
