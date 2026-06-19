# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"
require "time"

module Clacky
  module Server
    # Backs up the user's ~/.clacky directory to a safe location.
    #
    # Design notes:
    #   * Regenerable caches/logs are always excluded to keep archives small.
    #   * On WSL, the default destination is a Windows drive (/mnt/c|d|e) so
    #     backups survive a WSL distro reset.
    #   * Session history (sessions/ + snapshots/) is optional — it is the
    #     bulk of the data and the user may not want it in every archive.
    #   * Config lives in ~/.clacky/backup.yml, separate from config.yml so
    #     it never mixes with API keys.
    class BackupManager
      CLACKY_DIR  = File.expand_path("~/.clacky")
      CONFIG_FILE = File.join(CLACKY_DIR, "backup.yml")

      # Always excluded — regenerable or disposable.
      ALWAYS_EXCLUDE = %w[
        ocr_cache parsers parsers-1 logger safety_logs trash .DS_Store backup.yml
      ].freeze

      # Excluded unless the user opts into a full backup.
      HEAVY_EXCLUDE = %w[sessions snapshots].freeze

      DEFAULT_CONFIG = {
        "enabled"          => false,
        "cron"             => "0 3 * * *",
        "dest_dir"         => nil,
        "keep"             => 7,
        "include_sessions" => true,
        "last_run_at"      => nil,
        "last_status"      => nil,
        "last_error"       => nil,
        "last_archive"     => nil
      }.freeze

      class << self
        def config
          DEFAULT_CONFIG.merge(load_raw)
        end

        def update_config(enabled: nil, cron: nil, dest_dir: nil, keep: nil, include_sessions: nil)
          cfg = config
          cfg["enabled"]          = !!enabled            unless enabled.nil?
          cfg["cron"]             = cron.to_s            unless cron.nil?
          cfg["dest_dir"]         = normalize_dest(dest_dir) unless dest_dir.nil?
          cfg["keep"]             = [keep.to_i, 1].max   unless keep.nil?
          cfg["include_sessions"] = !!include_sessions   unless include_sessions.nil?
          save_raw(cfg)
          cfg
        end

        # Run a backup now. Returns a hash describing the result.
        def run!
          cfg     = config
          dest    = resolve_dest(cfg["dest_dir"])
          FileUtils.mkdir_p(dest)

          stamp   = Time.now.strftime("%Y%m%d-%H%M%S")
          archive = File.join(dest, "clacky-backup-#{stamp}.tar.gz")
          excludes = ALWAYS_EXCLUDE.dup
          excludes.concat(HEAVY_EXCLUDE) unless cfg["include_sessions"]

          ok = build_archive(archive, excludes)
          unless ok && File.exist?(archive)
            record_result(cfg, status: "error", error: "tar failed", archive: nil)
            raise "Backup failed: tar did not produce an archive"
          end

          prune(dest, cfg["keep"])
          record_result(cfg, status: "success", error: nil, archive: archive)

          { archive: archive, size: File.size(archive), dest_dir: dest }
        rescue => e
          Clacky::Logger.error("backup_run_error", error: e) if defined?(Clacky::Logger)
          record_result(config, status: "error", error: e.message, archive: nil)
          raise
        end

        # Build a one-off archive for direct download (not written to dest_dir,
        # not pruned, not recorded). Always includes session history so the
        # downloaded file is a complete snapshot. Caller is responsible for
        # deleting the returned temp file after streaming it.
        def build_download!
          stamp    = Time.now.strftime("%Y%m%d-%H%M%S")
          filename = "clacky-backup-#{stamp}.tar.gz"
          archive  = File.join(Dir.tmpdir, filename)

          ok = build_archive(archive, ALWAYS_EXCLUDE.dup)
          unless ok && File.exist?(archive)
            FileUtils.rm_f(archive)
            raise "Backup failed: tar did not produce an archive"
          end

          { path: archive, filename: filename, size: File.size(archive) }
        end

        # List existing backup archives at the resolved destination.
        def list
          dest = resolve_dest(config["dest_dir"])
          return [] unless Dir.exist?(dest)

          Dir.glob(File.join(dest, "clacky-backup-*.tar.gz")).map do |path|
            {
              "name"       => File.basename(path),
              "path"       => path,
              "size"       => File.size(path),
              "created_at" => File.mtime(path).iso8601
            }
          end.sort_by { |b| b["created_at"] }.reverse
        end

        # Resolved destination + whether we're on WSL (for UI display).
        def status
          dest = resolve_dest(config["dest_dir"])
          {
            "config"   => config,
            "dest_dir" => dest,
            "is_wsl"   => wsl?,
            "backups"  => list
          }
        end

        def wsl?
          @wsl ||= begin
            File.exist?("/proc/version") &&
              File.read("/proc/version").match?(/microsoft|wsl/i)
          rescue StandardError
            false
          end
        end

        # ── internals ──────────────────────────────────────────────────────

        # Where archives go when the user hasn't set an explicit dest_dir.
        def default_dest
          if wsl?
            %w[d c e].each do |drive|
              mount = "/mnt/#{drive}"
              return File.join(mount, "clacky_backups") if Dir.exist?(mount) && File.writable?(mount)
            end
          end
          File.expand_path("~/clacky_backups")
        end

        private def resolve_dest(dir)
          d = dir.to_s.strip
          d.empty? ? default_dest : File.expand_path(d)
        end

        private def normalize_dest(dir)
          d = dir.to_s.strip
          d.empty? ? nil : d
        end

        private def build_archive(archive, excludes)
          args = ["tar", "-czf", archive, "-C", CLACKY_DIR]
          excludes.each { |e| args << "--exclude=./#{e}" }
          args << "."
          system(*args)
        end

        private def prune(dest, keep)
          keep = [keep.to_i, 1].max
          all  = Dir.glob(File.join(dest, "clacky-backup-*.tar.gz")).sort_by { |f| File.mtime(f) }.reverse
          all.drop(keep).each { |f| FileUtils.rm_f(f) }
        end

        private def record_result(cfg, status:, error:, archive:)
          cfg = cfg.dup
          cfg["last_run_at"]  = Time.now.iso8601
          cfg["last_status"]  = status
          cfg["last_error"]   = error
          cfg["last_archive"] = archive ? File.basename(archive) : cfg["last_archive"]
          save_raw(cfg)
        end

        private def load_raw
          return {} unless File.exist?(CONFIG_FILE)

          YAMLCompat.load_file(CONFIG_FILE) || {}
        rescue StandardError
          {}
        end

        private def save_raw(cfg)
          FileUtils.mkdir_p(CLACKY_DIR)
          File.write(CONFIG_FILE, YAML.dump(cfg))
        end
      end
    end
  end
end
