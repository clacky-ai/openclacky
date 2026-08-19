# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "time"

module Clacky
  module Server
    # ProjectManager handles CRUD for "projects" — named groups that sessions
    # can be assigned to, analogous to ChatGPT / Codex Projects.
    #
    # Storage: ~/.clacky/projects.json
    # Each project entry shape:
    #   {
    #     id:          String (8-char hex),
    #     name:        String,
    #     description: String | null,
    #     color:       String | null (e.g. "#6366f1"),
    #     icon:        String | null (e.g. "folder", "code"),
    #     working_dir: String | null (absolute path; new sessions inherit this),
    #     pinned_at:   String | null (ISO8601; set when pinned, nil when not),
    #     created_at:  ISO8601,
    #     updated_at:  ISO8601
    #   }
    #
    # Thread-safety: a Mutex guards every read/write.
    class ProjectManager
      PROJECTS_FILE = File.join(Dir.home, ".clacky", "projects.json")

      def initialize(projects_file: nil)
        @projects_file = projects_file || PROJECTS_FILE
        @mutex         = Mutex.new
        @cache         = nil
      end

      # Return all projects sorted by created_at ascending (oldest first).
      def all
        @mutex.synchronize { load_projects.dup }
      end

      # Find a single project by id. Returns nil if not found.
      def find(id)
        @mutex.synchronize { load_projects.find { |p| p[:id] == id.to_s } }
      end

      # Create a new project. Returns the created project hash.
      # Required: name. Optional: description, color, icon, working_dir.
      def create(name:, description: nil, color: nil, icon: nil, working_dir: nil)
        raise ArgumentError, "name is required" if name.to_s.strip.empty?

        now     = Time.now.iso8601
        project = {
          id:          SecureRandom.hex(4),
          name:        name.to_s.strip,
          description: optional_str(description),
          color:       optional_str(color),
          icon:        optional_str(icon),
          working_dir: optional_str(working_dir),
          created_at:  now,
          updated_at:  now
        }

        @mutex.synchronize do
          projects = load_projects
          projects << project
          save_projects(projects)
        end

        project
      end

      # Update an existing project. Only explicitly passed (non-sentinel) keys
      # are changed. Pass description: nil or color: nil or icon: nil or working_dir: nil to clear those fields.
      # Pass pinned: true to pin (sets pinned_at to now), pinned: false to unpin.
      # Returns updated project hash, or nil if not found.
      def update(id, name: :__unset, description: :__unset, color: :__unset, icon: :__unset, working_dir: :__unset, pinned: :__unset)
        @mutex.synchronize do
          projects = load_projects
          project  = projects.find { |p| p[:id] == id.to_s }
          return nil unless project

          unless name == :__unset
            raise ArgumentError, "name cannot be empty" if name.to_s.strip.empty?

            project[:name] = name.to_s.strip
          end
          project[:description] = optional_str(description) unless description == :__unset
          project[:color]       = optional_str(color)       unless color == :__unset
          project[:icon]        = optional_str(icon)        unless icon == :__unset
          project[:working_dir] = optional_str(working_dir) unless working_dir == :__unset
          project[:pinned_at]   = pinned == true ? Time.now.iso8601 : nil unless pinned == :__unset
          project[:updated_at]  = Time.now.iso8601

          save_projects(projects)
          project.dup
        end
      end

      # Delete a project by id. Returns true if found and deleted, false otherwise.
      # NOTE: caller is responsible for clearing project_id on orphaned sessions.
      def delete(id)
        @mutex.synchronize do
          projects = load_projects
          before   = projects.size
          projects.reject! { |p| p[:id] == id.to_s }
          return false if projects.size == before

          save_projects(projects)
          true
        end
      end

      # ── Private helpers ───────────────────────────────────────────────────────

      # Load from disk (or return []). NOT mutex-protected — must be called
      # with @mutex held. Results cached until next save_projects.
      private def load_projects
        return @cache if @cache

        unless File.exist?(@projects_file)
          @cache = []
          return @cache
        end

        begin
          raw    = JSON.parse(File.read(@projects_file), symbolize_names: true)
          @cache = Array(raw).sort_by { |p| p[:created_at].to_s }
        rescue JSON::ParserError
          @cache = []
        end

        @cache
      end

      # Persist to disk and refresh cache. NOT mutex-protected.
      private def save_projects(projects)
        FileUtils.mkdir_p(File.dirname(@projects_file))
        File.write(@projects_file, JSON.pretty_generate(projects))
        FileUtils.chmod(0o600, @projects_file)
        @cache = projects
      end

      # Convert blank / nil values to nil for optional string fields.
      private def optional_str(value)
        return nil if value.nil?

        s = value.to_s.strip
        s.empty? ? nil : s
      end
    end
  end
end
