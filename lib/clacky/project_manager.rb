# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "time"

module Clacky
  # Lightweight project/folder registry for the WebUI.
  # Projects are explicit user-opened directories. Sessions still own working_dir;
  # association is by normalized absolute path.
  class ProjectManager
    DEFAULT_FILE = File.join(Dir.home, ".clacky", "projects.json")

    def initialize(file_path: nil)
      @file_path = file_path || DEFAULT_FILE
      @mutex = Mutex.new
      @cache = nil
      @cache_mtime = nil
      ensure_file!
    end

    def list
      @mutex.synchronize do
        load_projects.sort do |a, b|
          cmp = b[:last_opened_at].to_s <=> a[:last_opened_at].to_s
          cmp.zero? ? a[:name].to_s.downcase <=> b[:name].to_s.downcase : cmp
        end
      end
    end

    def get(id)
      @mutex.synchronize { load_projects.find { |p| p[:id] == id.to_s } }
    end

    def find_by_path(path)
      normalized = normalize_path(path)
      return nil if normalized.nil?

      @mutex.synchronize { load_projects.find { |p| p[:path] == normalized } }
    end

    def open(path, name: nil)
      normalized = normalize_path(path)
      raise ArgumentError, "path is required" if normalized.nil? || normalized.empty?
      raise ArgumentError, "Directory not found: #{normalized}" unless Dir.exist?(normalized)

      @mutex.synchronize do
        projects = load_projects
        existing = projects.find { |p| p[:path] == normalized }
        now = timestamp_now

        if existing
          existing[:last_opened_at] = now
          existing[:name] = name.strip unless name.nil? || name.strip.empty?
          save_projects!(projects)
          return existing.dup
        end

        project = {
          id: SecureRandom.hex(16),
          name: (name.nil? || name.strip.empty?) ? File.basename(normalized) : name.strip,
          path: normalized,
          created_at: now,
          last_opened_at: now
        }
        projects << project
        save_projects!(projects)
        project.dup
      end
    end

    def touch(id)
      @mutex.synchronize do
        projects = load_projects
        project = projects.find { |p| p[:id] == id.to_s }
        return nil unless project

        project[:last_opened_at] = timestamp_now
        save_projects!(projects)
        project.dup
      end
    end

    def rename(id, name)
      clean = name.to_s.strip
      raise ArgumentError, "name is required" if clean.empty?

      @mutex.synchronize do
        projects = load_projects
        project = projects.find { |p| p[:id] == id.to_s }
        return nil unless project

        project[:name] = clean
        project[:last_opened_at] = timestamp_now
        save_projects!(projects)
        project.dup
      end
    end

    def remove(id)
      @mutex.synchronize do
        projects = load_projects
        before = projects.size
        projects.reject! { |p| p[:id] == id.to_s }
        return false if projects.size == before

        save_projects!(projects)
        true
      end
    end

    # Canonical absolute path for project/session association.
    def normalize_path(path)
      raw = path.to_s.strip
      return nil if raw.empty?

      expanded = File.expand_path(raw.start_with?("~") ? raw.sub(/\A~/, Dir.home) : raw)
      absolute = File.absolute_path(expanded)
      return File.realpath(absolute) if File.exist?(absolute)

      absolute
    rescue StandardError
      nil
    end

    # Millisecond ISO-8601 so rapid open/touch keeps stable MRU order.
    private def timestamp_now
      Time.now.utc.iso8601(3)
    end

    private def ensure_file!
      dir = File.dirname(@file_path)
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
      return if File.exist?(@file_path)

      File.write(@file_path, JSON.pretty_generate({ "projects" => [] }))
      FileUtils.chmod(0o600, @file_path)
    end

    private def load_projects
      ensure_file!
      mtime = begin
        File.mtime(@file_path)
      rescue Errno::ENOENT
        nil
      end
      if @cache && @cache_mtime && mtime && @cache_mtime == mtime
        return @cache.map(&:dup)
      end

      raw = JSON.parse(File.read(@file_path))
      list = raw.is_a?(Hash) ? (raw["projects"] || raw[:projects] || []) : []
      projects = Array(list).filter_map { |item| normalize_record(item) }
      @cache = projects
      @cache_mtime = mtime
      projects.map(&:dup)
    rescue JSON::ParserError => e
      backup_corrupt_file!(e)
      @cache = []
      @cache_mtime = begin
        File.mtime(@file_path)
      rescue StandardError
        nil
      end
      []
    rescue Errno::ENOENT
      @cache = []
      @cache_mtime = nil
      []
    end

    private def backup_corrupt_file!(error)
      return unless File.exist?(@file_path)

      stamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      backup = "#{@file_path}.corrupt.#{stamp}"
      FileUtils.cp(@file_path, backup)
      FileUtils.chmod(0o600, backup)
      warn "[ProjectManager] corrupt projects file backed up to #{backup}: #{error.message}"
      File.write(@file_path, JSON.pretty_generate({ "projects" => [] }))
      FileUtils.chmod(0o600, @file_path)
    rescue StandardError => e
      warn "[ProjectManager] failed to backup corrupt projects file: #{e.message}"
    end

    private def save_projects!(projects)
      ensure_file!
      payload = {
        "projects" => projects.map do |p|
          {
            "id" => p[:id],
            "name" => p[:name],
            "path" => p[:path],
            "created_at" => p[:created_at],
            "last_opened_at" => p[:last_opened_at]
          }
        end
      }
      tmp = "#{@file_path}.tmp"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(JSON.pretty_generate(payload))
        f.flush
        f.fsync
      end
      FileUtils.chmod(0o600, tmp)
      FileUtils.mv(tmp, @file_path)
      @cache = projects.map(&:dup)
      @cache_mtime = begin
        File.mtime(@file_path)
      rescue StandardError
        nil
      end
    end

    private def normalize_record(item)
      return nil unless item.is_a?(Hash)

      id = (item["id"] || item[:id]).to_s
      path = normalize_path(item["path"] || item[:path])
      return nil if id.empty? || path.nil?

      {
        id: id,
        name: (item["name"] || item[:name] || File.basename(path)).to_s,
        path: path,
        created_at: (item["created_at"] || item[:created_at]).to_s,
        last_opened_at: (item["last_opened_at"] || item[:last_opened_at]).to_s
      }
    end
  end
end
