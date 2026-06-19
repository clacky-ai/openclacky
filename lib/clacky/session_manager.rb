# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "open3"
require "set"

module Clacky
  class SessionManager
    SESSIONS_DIR = File.join(Dir.home, ".clacky", "sessions")

    # Generate a new unique session ID (16-char hex string).
    # This is the single authoritative source for session IDs — all components
    # (Agent, SessionRegistry) should receive an ID generated here rather than
    # creating their own.
    def self.generate_id
      SecureRandom.hex(8)
    end

    def initialize(sessions_dir: nil)
      @sessions_dir = sessions_dir || SESSIONS_DIR
      ensure_sessions_dir
    end

    # Save a session. Returns the file path.
    def save(session_data)
      filename = generate_filename(session_data[:session_id], session_data[:created_at])
      filepath = File.join(@sessions_dir, filename)

      File.write(filepath, JSON.pretty_generate(session_data))
      FileUtils.chmod(0o600, filepath)

      @last_saved_path = filepath

      # Keep only the most recent 200 sessions (best-effort, never block save)
      begin
        cleanup_by_count(keep: 200)
      rescue Exception # rubocop:disable Lint/RescueException
        # Cleanup is non-critical; swallow all errors (including AgentInterrupted)
      end

      filepath
    end

    # Path of the last saved session file.
    def last_saved_path
      @last_saved_path
    end

    # Load a specific session by ID. Returns nil if not found.
    def load(session_id)
      all_sessions.find { |s| s[:session_id].to_s.start_with?(session_id.to_s) }
    end

    # Fork a session: create a copy with new id, "(copy)" name suffix, and reset stats.
    # Returns the forked session data hash, or nil if the original is not found.
    def fork(session_id)
      original = load(session_id)
      return nil unless original

      forked = original.dup
      forked[:session_id]  = self.class.generate_id
      forked[:created_at]  = Time.now.iso8601
      forked[:updated_at]  = Time.now.iso8601
      forked[:pinned]      = false
      forked[:name]        = "#{original[:name] || "Unnamed session"} (copy)"
      forked[:stats] = (original[:stats] || {}).merge(
        total_tasks: 0, total_iterations: 0, total_cost_usd: 0.0,
        last_status: nil, last_error: nil
      )

      save(forked)
      forked
    end

    # Soft-delete: move session JSON + chunks to the session trash directory.
    # Returns true if found and moved, false if not found.
    def delete(session_id)
      soft_delete(session_id)
    end

    # Return the on-disk files associated with a session: the main JSON file
    # and any "{base}-chunk-*.md" archive files. Used by the export / download
    # endpoint so the UI can bundle everything a user may need for debugging.
    # Returns nil if the session is not found, or a Hash:
    #   {
    #     session:   Hash,        # the loaded session metadata
    #     json_path: String,      # absolute path to session.json
    #     chunks:    [String]     # sorted absolute paths to chunk *.md files
    #   }
    def files_for(session_id)
      session = all_sessions.find { |s| s[:session_id].to_s.start_with?(session_id.to_s) }
      return nil unless session

      json_path = File.join(@sessions_dir, generate_filename(session[:session_id], session[:created_at]))
      return nil unless File.exist?(json_path)

      base   = File.basename(json_path, ".json")
      chunks = Dir.glob(File.join(@sessions_dir, "#{base}-chunk-*.md")).sort

      { session: session, json_path: json_path, chunks: chunks }
    end

    # ── Chunk file I/O (for conversation compression archives) ────────────────
    #
    # The SessionManager is the single owner of sessions/{base}-chunk-N.md
    # file naming, writing, discovery, and deletion. Everything else in the
    # codebase (MessageCompressorHelper, SessionSerializer) should go through
    # these methods rather than building paths or scanning the directory
    # directly — this keeps the on-disk layout under one roof and makes it
    # easy to evolve (e.g. add encryption, switch to a DB).

    # Discover all chunk MD files on disk for a given session.
    # Returns them sorted by chunk index ascending (oldest first).
    #
    # @param session_id [String] full session id (or at least first 8 chars)
    # @param created_at [String] ISO-8601 timestamp used in the base filename
    # @return [Array<Hash>] each with :index, :path, :basename, :topics
    def chunks_for_current(session_id, created_at)
      return [] unless session_id && created_at

      base = chunk_base_name(session_id, created_at)
      pattern = File.join(@sessions_dir, "#{base}-chunk-*.md")

      Dir.glob(pattern).filter_map do |path|
        basename = File.basename(path)
        # Extract integer index from "<base>-chunk-<N>.md"
        m = basename.match(/-chunk-(\d+)\.md\z/)
        next nil unless m

        {
          index: m[1].to_i,
          path: path,
          basename: basename,
          topics: read_chunk_topics(path)
        }
      end.sort_by { |c| c[:index] }
    end

    # Next unused chunk index for a session, derived from disk.
    # This is the ONLY correct way to compute the next chunk index —
    # counting compressed_summary messages in history caps at 1 after the
    # second compression (rebuild keeps only the latest summary) and
    # in-memory counters reset on process restart.
    def next_chunk_index(session_id, created_at)
      existing = chunks_for_current(session_id, created_at)
      (existing.map { |c| c[:index] }.max || 0) + 1
    end

    # Write a chunk MD file to disk. Returns the absolute path.
    # Caller is responsible for generating the MD content — this method
    # only handles filesystem concerns (path assembly, write, chmod).
    def write_chunk(session_id, created_at, chunk_index, md_content)
      return nil unless session_id && created_at

      base = chunk_base_name(session_id, created_at)
      chunk_path = File.join(@sessions_dir, "#{base}-chunk-#{chunk_index}.md")

      File.write(chunk_path, md_content)
      FileUtils.chmod(0o600, chunk_path)

      chunk_path
    end

    # All sessions from disk, newest-first (sorted by last activity / updated_at,
    # falling back to created_at for legacy sessions without updated_at).
    # Optional filters:
    #   current_dir: (String) if given, sessions matching working_dir come first
    #   limit:       (Integer) max number of sessions to return
    def all_sessions(current_dir: nil, limit: nil)
      sessions = Dir.glob(File.join(@sessions_dir, "*.json")).filter_map do |filepath|
        load_session_file(filepath)
      end.sort_by { |s| s[:updated_at] || s[:created_at] || "" }.reverse

      if current_dir
        current_sessions = sessions.select { |s| s[:working_dir] == current_dir }
        other_sessions   = sessions.reject { |s| s[:working_dir] == current_dir }
        sessions = current_sessions + other_sessions
      end

      limit ? sessions.first(limit) : sessions
    end

    # Full-text grep over session JSON + chunk MD files.
    # Case-sensitive: BSD grep -i is ~30x slower; Chinese has no case.
    # Returns Hash<short_id String => snippet String> (snippet around the first match).
    def search_content(query, timeout: 5)
      q = query.to_s
      return {} if q.strip.length < 2

      files = Dir.glob(File.join(@sessions_dir, "*.json")) +
              Dir.glob(File.join(@sessions_dir, "*-chunk-*.md"))
      return {} if files.empty?

      result = {}
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      each_grep_batch(files) do |batch|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0
        out = run_with_timeout({ "LC_ALL" => "C" },
                               "grep", "-H", "-F", "-m", "1", "--",
                               q, *batch,
                               timeout: remaining)
        next unless out
        out.each_line do |line|
          path, _, rest = line.chomp.partition(":")
          next if path.empty? || rest.empty?
          sid = extract_short_id(File.basename(path))
          next unless sid
          next if result.key?(sid)
          result[sid] = build_snippet(rest, q)
        end
      end
      result
    end

    # Yield file batches whose joined argv length stays well under ARG_MAX.
    # macOS ARG_MAX is ~256 KiB; we cap at 96 KiB to leave room for env.
    private def each_grep_batch(files, max_bytes: 96 * 1024)
      batch = []
      size  = 0
      files.each do |f|
        len = f.bytesize + 1
        if size + len > max_bytes && !batch.empty?
          yield batch
          batch = []
          size  = 0
        end
        batch << f
        size  += len
      end
      yield batch unless batch.empty?
    end

    private def build_snippet(line, query, radius: 80)
      bytes = line.b
      q = query.b
      idx = bytes.index(q)
      if idx.nil?
        head = bytes.byteslice(0, radius * 2).to_s
        return head.force_encoding("UTF-8").scrub("?").gsub(/\s+/, " ").strip
      end

      start_byte = [idx - radius, 0].max
      stop_byte  = [idx + q.bytesize + radius, bytes.bytesize].min
      snippet = bytes.byteslice(start_byte, stop_byte - start_byte).to_s
      snippet = snippet.force_encoding("UTF-8").scrub("?")
      snippet = "…" + snippet if start_byte > 0
      snippet = snippet + "…" if stop_byte < bytes.bytesize
      snippet.gsub(/\s+/, " ").strip
    end

    private def run_with_timeout(env, *cmd, timeout:)
      Open3.popen3(env, *cmd) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        out = +""
        reader = Thread.new { out << stdout.read }
        drain  = Thread.new { stderr.read }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0
          break if wait_thr.join(remaining)
        end
        if wait_thr.alive?
          Process.kill("TERM", wait_thr.pid) rescue nil
          wait_thr.join(0.5)
          Process.kill("KILL", wait_thr.pid) rescue nil if wait_thr.alive?
          reader.kill; drain.kill
          return nil
        end
        reader.join; drain.join
        out
      end
    end

    private def extract_short_id(basename)
      m = basename.match(/-([0-9a-f]{8})(?:-chunk-\d+)?\.(?:json|md)\z/)
      m && m[1]
    end

    # Return the most recent session for a given working directory, or nil.
    def latest_for_directory(working_dir)
      all_sessions(current_dir: working_dir).first
    end

    # Delete sessions not accessed within the given number of days (default: 90).
    # Returns count of deleted sessions.
    def cleanup(days: 90)
      cutoff = Time.now - (days * 24 * 60 * 60)
      deleted = 0
      Dir.glob(File.join(@sessions_dir, "*.json")).each do |filepath|
        session = load_session_file(filepath)
        next unless session
        if Time.parse(session[:updated_at]) < cutoff
          _hard_delete_session_with_chunks(filepath)
          deleted += 1
        end
      end
      deleted
    end

    # Keep only the most recent N non-pinned sessions by created_at; the rest
    # are soft-deleted (moved to the session trash, recoverable). Pinned
    # sessions are never deleted and do not count toward the cap.
    # Returns count of soft-deleted sessions.
    def cleanup_by_count(keep:)
      non_pinned = all_sessions.reject { |s| s[:pinned] } # already sorted newest-first
      return 0 if non_pinned.size <= keep

      victims = non_pinned[keep..]
      victims.each { |session| soft_delete(session[:session_id]) }
      victims.size
    end

    # ── Session trash (delegates to Tools::TrashManager) ──────────────
    # All business logic lives in Clacky::Tools::TrashManager; SessionManager
    # only provides the sessions_dir context and filesystem helpers used there.

    # Soft-delete: stamp deleted_at, move JSON + chunks to sessions-trash/.
    def soft_delete(session_id)
      require_relative "tools/trash_manager"
      Clacky::Tools::TrashManager.soft_delete_session(session_id, sessions_dir: @sessions_dir)
    end

    # Restore a soft-deleted session back to the active sessions directory.
    def restore_session(session_id)
      require_relative "tools/trash_manager"
      Clacky::Tools::TrashManager.restore_session(session_id, sessions_dir: @sessions_dir)
    end

    # List all soft-deleted sessions (newest-first).
    def list_trash_sessions
      require_relative "tools/trash_manager"
      Clacky::Tools::TrashManager.list_trash_sessions(sessions_dir: @sessions_dir)
    end

    # Permanently delete one session from the trash — cannot be undone.
    def permanent_delete_trash_session(session_id)
      require_relative "tools/trash_manager"
      Clacky::Tools::TrashManager.permanent_delete_trash_session(session_id, sessions_dir: @sessions_dir)
    end

    # Clean up soft-deleted sessions older than :days (default: 90).
    def cleanup_trash(days: 90)
      require_relative "tools/trash_manager"
      Clacky::Tools::TrashManager.empty_trash_sessions(sessions_dir: @sessions_dir, days: days)
    end


    def ensure_sessions_dir
      FileUtils.mkdir_p(@sessions_dir) unless Dir.exist?(@sessions_dir)
    end

    def generate_filename(session_id, created_at)
      "#{chunk_base_name(session_id, created_at)}.json"
    end

    # Base name (without extension) shared by a session's .json file and its
    # chunk-N.md archive files. Kept as a single source of truth so chunk
    # I/O stays consistent with the session filename.
    private def chunk_base_name(session_id, created_at)
      datetime = Time.parse(created_at).strftime("%Y-%m-%d-%H-%M-%S")
      short_id = session_id[0..7]
      "#{datetime}-#{short_id}"
    end

    # Read the `topics:` field from a chunk MD file's YAML-like front matter.
    # Only scans the first ~20 lines — front matter is tiny and we don't
    # want to read megabytes of archived conversation just to grab one line.
    # Returns nil if the file is missing, unreadable, or has no topics.
    private def read_chunk_topics(path)
      return nil unless File.exist?(path)

      lines = []
      File.open(path, "r") do |f|
        20.times do
          line = f.gets
          break if line.nil?
          lines << line
        end
      end

      in_front_matter = false
      lines.each do |line|
        stripped = line.strip
        if stripped == "---"
          break if in_front_matter
          in_front_matter = true
          next
        end
        next unless in_front_matter

        if (m = stripped.match(/\Atopics:\s*(.+)\z/))
          topics = m[1].strip
          return topics.empty? ? nil : topics
        end
      end
      nil
    rescue
      nil
    end

    # Delete a session JSON file and all its associated chunk MD files.
    private def _hard_delete_session_with_chunks(json_filepath)
      File.delete(json_filepath) if File.exist?(json_filepath)
      base = File.basename(json_filepath, ".json")
      Dir.glob(File.join(File.dirname(json_filepath), "#{base}-chunk-*.md")).each { |f| File.delete(f) }
    end

    def load_session_file(filepath)
      JSON.parse(File.read(filepath), symbolize_names: true)
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    # Remove Time Machine snapshots that no longer belong to any known session.
    # Snapshots are keyed by full session_id; session files are named by the
    # 8-char id prefix, so a snapshot dir is an orphan when its prefix matches
    # no active or trashed session file. Returns the count of removed dirs.
    def self.cleanup_orphan_snapshots(sessions_dir: SESSIONS_DIR, snapshots_root: nil)
      snapshots_root ||= File.join(Dir.home, ".clacky", "snapshots")
      return 0 unless Dir.exist?(snapshots_root)

      require_relative "utils/trash_directory"
      known = _session_id_prefixes(File.join(sessions_dir, "*.json"))
      trash_dir = Clacky::TrashDirectory.sessions_trash_dir
      known += _session_id_prefixes(File.join(trash_dir, "*.json")) if Dir.exist?(trash_dir)
      known = known.to_set

      removed = 0
      Dir.children(snapshots_root).each do |name|
        dir = File.join(snapshots_root, name)
        next unless File.directory?(dir)
        next if known.include?(name[0, 8])

        FileUtils.rm_rf(dir)
        removed += 1
      end
      removed
    end

    # Session filenames look like "<datetime>-<8hexid>.json"; pull out the
    # trailing 8-char id prefix, which matches a snapshot dir's name prefix.
    def self._session_id_prefixes(glob)
      Dir.glob(glob).filter_map do |p|
        m = File.basename(p, ".json").match(/-([0-9a-f]{8})\z/)
        m && m[1]
      end
    end
    private_class_method :_session_id_prefixes
  end
end
