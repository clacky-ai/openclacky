# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"

module Clacky
  # Content-addressed storage for self-contained visualization fragments.
  # Artifacts are immutable: identical HTML reuses the same file and URL.
  class ArtifactStore
    DEFAULT_ROOT = File.join(Dir.home, ".clacky", "artifacts")
    MAX_BYTES = 512 * 1024
    ID_PATTERN = /\A[0-9a-f]{64}\z/.freeze

    class Error < StandardError; end

    def initialize(root: DEFAULT_ROOT)
      @root = File.expand_path(root)
    end

    def write(html)
      content = html.to_s
      raise Error, "HTML must be valid UTF-8" unless content.valid_encoding?
      raise Error, "HTML cannot be empty" if content.strip.empty?
      raise Error, "HTML exceeds #{MAX_BYTES} bytes" if content.bytesize > MAX_BYTES

      artifact_id = Digest::SHA256.hexdigest(content)
      path = artifact_path(artifact_id)
      return metadata(artifact_id, content) if File.file?(path)

      FileUtils.mkdir_p(@root, mode: 0o700)
      temp_path = File.join(@root, ".#{artifact_id}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp")
      begin
        File.open(temp_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(content)
          file.flush
          file.fsync
        end
        File.rename(temp_path, path) unless File.exist?(path)
      ensure
        File.delete(temp_path) if File.exist?(temp_path)
      end

      metadata(artifact_id, content)
    rescue SystemCallError => e
      raise Error, "Failed to store artifact: #{e.message}"
    end

    def read(artifact_id)
      return nil unless valid_id?(artifact_id)

      path = artifact_path(artifact_id)
      File.file?(path) ? File.read(path, encoding: Encoding::UTF_8) : nil
    rescue SystemCallError, EncodingError
      nil
    end

    def valid_id?(artifact_id)
      ID_PATTERN.match?(artifact_id.to_s)
    end

    private def artifact_path(artifact_id)
      File.join(@root, "#{artifact_id}.html")
    end

    private def metadata(artifact_id, content)
      { id: artifact_id, bytes: content.bytesize }
    end
  end
end
