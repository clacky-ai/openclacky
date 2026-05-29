# frozen_string_literal: true

require "digest"
require "fileutils"

module Clacky
  # Manages global trash directory at ~/.clacky/trash.
  # Organises both file-trash and session-trash under one root:
  #   ~/.clacky/trash/
  #   ├── file-trash/      ← AI-deleted project files, keyed by project hash
  #   └── sessions-trash/  ← soft-deleted sessions (JSON + chunk MD files)
  class TrashDirectory
    GLOBAL_TRASH_ROOT = File.join(Dir.home, ".clacky", "trash")

    def self.files_trash_dir
      File.join(GLOBAL_TRASH_ROOT, "file-trash")
    end

    def self.sessions_trash_dir
      File.join(GLOBAL_TRASH_ROOT, "sessions-trash")
    end

    attr_reader :project_root, :trash_dir, :backup_dir

    def initialize(project_root = Dir.pwd)
      @project_root = File.expand_path(project_root)
      @project_hash = generate_project_hash(@project_root)
      @trash_dir = File.join(self.class.files_trash_dir, @project_hash)
      @backup_dir = File.join(@trash_dir, "backups")
      
      setup_directories
    end

    # Generate a unique hash for project path
    def generate_project_hash(path)
      # Use MD5 hash of the absolute path, take first 16 chars for readability
      hash = Digest::MD5.hexdigest(path)[0..15]
      # Also include a readable suffix based on project name
      project_name = File.basename(path).gsub(/[^a-zA-Z0-9_-]/, '_')[0..20]
      "#{hash}_#{project_name}"
    end

    # Setup trash and backup directories with proper structure
    def setup_directories
      [@trash_dir, @backup_dir].each do |dir|
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

        # Create .gitignore file to avoid trash files being committed
        gitignore_path = File.join(dir, '.gitignore')
        unless File.exist?(gitignore_path)
          File.write(gitignore_path, "*\n!.gitignore\n")
        end
      end

      # Create project metadata file
      create_project_metadata
    end

    # Create or update metadata about this project
    def create_project_metadata
      metadata_file = File.join(@trash_dir, '.project_metadata.json')
      
      metadata = {
        project_root: @project_root,
        project_name: File.basename(@project_root),
        project_hash: @project_hash,
        created_at: File.exist?(metadata_file) ? JSON.parse(File.read(metadata_file))['created_at'] : Time.now.iso8601,
        last_accessed: Time.now.iso8601
      }
      
      File.write(metadata_file, JSON.pretty_generate(metadata))
    rescue StandardError => e
      # Log warning but don't block operation
      warn "Warning: Could not create project metadata: #{e.message}"
    end

    # ── Legacy migration ──────────────────────────────────────────────

    OLD_TRASH_ROOT = File.join(Dir.home, ".clacky", "trash")

    # One-time: move pre-file-trash project hash dirs from ~/.clacky/trash/
    # directly into the new file-trash/ subdirectory. Safe to call on every boot.
    def self.migrate_legacy_if_needed
      return unless Dir.exist?(OLD_TRASH_ROOT)

      FileUtils.mkdir_p(files_trash_dir)

      Dir.glob(File.join(OLD_TRASH_ROOT, "*")).each do |entry|
        basename = File.basename(entry)
        next if %w[file-trash sessions-trash].include?(basename)
        next if File.directory?(File.join(files_trash_dir, basename))

        FileUtils.mv(entry, files_trash_dir)
      end
    end

    # Get all project directories that have trash
    def self.all_projects
      return [] unless Dir.exist?(files_trash_dir)
      
      projects = []
      Dir.glob(File.join(files_trash_dir, "*", ".project_metadata.json")).each do |metadata_file|
        begin
          metadata = JSON.parse(File.read(metadata_file))
          projects << {
            project_root: metadata['project_root'],
            project_name: metadata['project_name'],
            project_hash: metadata['project_hash'],
            trash_dir: File.dirname(metadata_file),
            last_accessed: metadata['last_accessed']
          }
        rescue StandardError
          # Skip corrupted metadata
        end
      end
      
      projects.sort_by { |p| p[:last_accessed] }.reverse
    end

    # Get trash directory for a specific project
    def self.for_project(project_root)
      new(project_root)
    end

    # Clean up trash directories for non-existent projects
    def self.cleanup_orphaned_projects
      return 0 unless Dir.exist?(files_trash_dir)
      
      cleaned_count = 0
      all_projects.each do |project|
        unless Dir.exist?(project[:project_root])
          # Project no longer exists, optionally remove trash
          # For safety, we'll just mark it as orphaned
          orphan_file = File.join(project[:trash_dir], '.orphaned')
          File.write(orphan_file, "Original project path no longer exists: #{project[:project_root]}\n")
          cleaned_count += 1
        end
      end
      
      cleaned_count
    end
  end
end
