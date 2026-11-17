# frozen_string_literal: true

require "yaml"
require "json"
require "date"
require "time"
require "fileutils"

module Clacky
  module Knowledge
    # Reads a knowledge pack from disk:
    #
    #   <root>/kb.yml            version / enabled / tuning
    #   <root>/entries/**/*.md   one document per file, optional YAML frontmatter
    #
    # Sub-folders of entries/ are the user-facing structure (book → chapter →
    # …, any depth); `folder` is an entry's folder relative to entries/ ("" =
    # top level). Retrieval ignores folders and always covers everything.
    #
    # Frontmatter keys: id, title, source. Missing id falls back to the path
    # relative to entries/ (without .md); missing title to the file name. A
    # legacy `category` key is ignored.
    class Store
      Entry = Struct.new(:id, :title, :folder, :source, :path, :body, keyword_init: true)

      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root)
      end

      def config_path
        File.join(@root, "kb.yml")
      end

      def entries_dir
        File.join(@root, "entries")
      end

      def config
        return {} unless File.file?(config_path)
        data = YAML.safe_load(File.read(config_path, encoding: "UTF-8"), permitted_classes: [Date, Time])
        data.is_a?(Hash) ? data : {}
      end

      # On as soon as entries/ holds a .md file; kb.yml is optional and only
      # needed to switch it off (enabled: false) or tune it.
      def enabled?
        config["enabled"] != false && entry_paths.any?
      end

      # Create entries/ so users have an obvious place to drop files.
      def ensure_dirs!
        FileUtils.mkdir_p(entries_dir)
      rescue SystemCallError
        nil
      end

      def entry_paths
        Dir.glob(File.join(entries_dir, "**", "*.md")).sort
      end

      # Every folder under entries/ (empty ones included), relative, sorted.
      def folders
        Dir.glob(File.join(entries_dir, "**", "*/")).map { |d| relative(d.chomp("/")) }
           .reject { |d| d.split("/").any? { |s| s.start_with?(".") } }.sort
      end

      # Cheap fingerprint used to decide whether the index must be rebuilt.
      def signature
        [config_path, *entry_paths].map { |p| File.file?(p) ? [p, File.mtime(p).to_f, File.size(p)] : [p] }
      end

      def entries
        entry_paths.map { |path| load_entry(path) }
      end

      def find(id)
        entries.find { |e| e.id == id.to_s }
      end

      # ── Writes (management panel) ──────────────────────────────────────
      # Entries are addressed by their path relative to entries/ ("a/b.md"),
      # not by id: ids come from user-editable frontmatter and may collide.

      class PathError < StandardError; end

      # Absolute path for a relative entry path; raises PathError unless it is
      # a .md file strictly inside entries/ (no "..", no absolute paths).
      def resolve(rel)
        rel = rel.to_s.strip
        raise PathError, "path required" if rel.empty?
        raise PathError, "must be a .md file" unless rel.end_with?(".md")
        base = File.expand_path(entries_dir)
        abs = File.expand_path(rel, base)
        raise PathError, "path escapes entries/" unless abs.start_with?(base + File::SEPARATOR)
        abs
      end

      def relative(abs)
        abs.delete_prefix(File.expand_path(entries_dir) + File::SEPARATOR)
      end

      # Absolute path for a relative folder ("" / nil = entries/ itself);
      # raises PathError if it escapes entries/.
      def resolve_folder(rel)
        rel = rel.to_s.strip.delete_prefix("/").chomp("/")
        base = File.expand_path(entries_dir)
        return base if rel.empty?
        abs = File.expand_path(rel, base)
        raise PathError, "path escapes entries/" unless abs.start_with?(base + File::SEPARATOR)
        abs
      end

      # Folder of an entry relative to entries/, "" for the top level.
      def folder_of(abs)
        dir = File.dirname(abs)
        dir == File.expand_path(entries_dir) ? "" : relative(dir)
      end

      def load(rel)
        abs = resolve(rel)
        File.file?(abs) ? load_entry(abs) : nil
      end

      # Create (rel nil) or overwrite (rel given) an entry. Frontmatter keys the
      # panel does not edit (e.g. a hand-written id) are preserved on update.
      # New entries go to entries/<folder>/<title>.md, de-duplicated; the
      # folder path is sanitised segment by segment and created as needed.
      # Returns the relative path written.
      def save(rel: nil, folder: nil, title:, source: nil, body: "")
        title = title.to_s.strip
        raise PathError, "title required" if title.empty?

        if rel.to_s.strip.empty?
          abs = unique_path(File.join(*[safe_folder(folder), "#{safe_segment(title) || 'untitled'}.md"].reject(&:empty?)))
          meta = {}
        else
          abs = resolve(rel)
          meta = File.file?(abs) ? split_frontmatter(File.read(abs, encoding: "UTF-8").scrub(""))[0] : {}
        end

        meta = meta.except("category").merge("title" => title, "source" => blank_to_nil(source))
        meta.delete_if { |_k, v| v.nil? }
        FileUtils.mkdir_p(File.dirname(abs))
        front = meta.empty? ? "" : "#{YAML.dump(meta)}---\n\n"
        File.write(abs, "#{front}#{body.to_s.strip}\n")
        relative(abs)
      end

      # Soft delete: move into the shared ~/.clacky/trash with the same
      # metadata sidecar safe_rm writes, so the file stays recoverable. The
      # folder is kept even when it becomes empty — folders are user-made.
      def trash(rel, trash_dir:)
        abs = resolve(rel)
        raise PathError, "not found" unless File.file?(abs)
        FileUtils.mkdir_p(trash_dir)
        dest = File.join(trash_dir, "#{File.basename(abs)}_deleted_#{Time.now.strftime('%Y%m%d_%H%M%S_%N')}")
        size = File.size(abs)
        FileUtils.mv(abs, dest)
        File.write("#{dest}.metadata.json", JSON.generate(
          original_path: abs, trash_directory: trash_dir, deleted_at: Time.now.utc.iso8601,
          deleted_by: "knowledge_panel", file_size: size, file_type: ".md", file_mode: "644"
        ))
        dest
      end

      # Move an entry into another folder (same file name, de-duplicated).
      # Returns the new relative path.
      def move(rel, folder)
        abs = resolve(rel)
        raise PathError, "not found" unless File.file?(abs)
        dir = resolve_folder(safe_folder(folder))
        return rel if File.dirname(abs) == dir
        dest = unique_path(File.join(*[safe_folder(folder), File.basename(abs)].reject(&:empty?)))
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.mv(abs, dest)
        relative(dest)
      end

      # ── Folders ────────────────────────────────────────────────────────

      # Create <parent>/<name>. Returns its relative path.
      def create_folder(parent, name)
        seg = safe_segment(name)
        raise PathError, "name required" unless seg
        abs = File.join(resolve_folder(parent), seg)
        raise PathError, "already exists" if File.exist?(abs)
        FileUtils.mkdir_p(abs)
        relative(abs)
      end

      # Rename a folder in place. Returns its new relative path.
      def rename_folder(rel, name)
        abs = existing_folder(rel)
        seg = safe_segment(name)
        raise PathError, "name required" unless seg
        dest = File.join(File.dirname(abs), seg)
        return relative(abs) if dest == abs
        raise PathError, "already exists" if File.exist?(dest)
        File.rename(abs, dest)
        relative(dest)
      end

      # Soft-delete a folder and everything in it (same trash as entries).
      def trash_folder(rel, trash_dir:)
        abs = existing_folder(rel)
        FileUtils.mkdir_p(trash_dir)
        dest = File.join(trash_dir, "#{File.basename(abs)}_deleted_#{Time.now.strftime('%Y%m%d_%H%M%S_%N')}")
        FileUtils.mv(abs, dest)
        File.write("#{dest}.metadata.json", JSON.generate(
          original_path: abs, trash_directory: trash_dir, deleted_at: Time.now.utc.iso8601,
          deleted_by: "knowledge_panel", file_size: 0, file_type: "directory", file_mode: "755"
        ))
        dest
      end

      # Split a "---" frontmatter block off raw markdown → [meta, body].
      def parse_markdown(raw)
        split_frontmatter(raw.to_s)
      end

      # File/dir-name safe version of a user label; keeps CJK, drops path
      # separators and characters Windows/macOS reject. nil when blank.
      private def safe_segment(name)
        s = name.to_s.strip.gsub(%r{[/\\:*?"<>|\x00-\x1f]}, "-").gsub(/\A\.+/, "").strip
        s = s[0, 80]
        s.empty? ? nil : s
      end

      # "a / b:c/../d" → "a/b-c/d": each segment made safe, blanks and dot
      # segments dropped. "" for the top level.
      private def safe_folder(path)
        path.to_s.split(%r{[/\\]}).filter_map { |s| safe_segment(s) }.join("/")
      end

      private def existing_folder(rel)
        raise PathError, "folder required" if rel.to_s.strip.delete_prefix("/").chomp("/").empty?
        abs = resolve_folder(rel)
        raise PathError, "not found" unless File.directory?(abs)
        abs
      end

      private def unique_path(rel)
        abs = resolve(rel)
        stem = abs.delete_suffix(".md")
        n = 1
        abs = "#{stem}-#{n += 1}.md" while File.exist?(abs)
        abs
      end

      private def blank_to_nil(v)
        s = v.to_s.strip
        s.empty? ? nil : s
      end

      private def load_entry(path)
        raw = File.read(path, encoding: "UTF-8").scrub("")
        meta, body = split_frontmatter(raw)
        rel = path.delete_prefix(entries_dir + "/").delete_suffix(".md")
        Entry.new(
          id: (meta["id"] || rel).to_s,
          title: (meta["title"] || File.basename(rel)).to_s,
          folder: folder_of(path),
          source: meta["source"]&.to_s,
          path: path,
          body: body
        )
      end

      private def split_frontmatter(raw)
        match = raw.match(/\A---\s*\n(.*?)\n---\s*(?:\n|\z)/m)
        return [{}, raw] unless match
        meta = YAML.safe_load(match[1], permitted_classes: [Date, Time])
        [meta.is_a?(Hash) ? meta : {}, match.post_match]
      rescue Psych::Exception
        [{}, raw]
      end
    end
  end
end
