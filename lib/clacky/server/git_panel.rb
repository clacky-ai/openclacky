# frozen_string_literal: true

require "open3"

module Clacky
  module Server
    # Read-mostly git operations scoped to a session's working directory, backing
    # the official "git" WebUI panel. Commands run with explicit argv (no shell),
    # so user-supplied values (paths, messages) cannot inject. Write operations
    # are limited to a guarded `commit` and a single-file `restore`;
    # history-rewriting / remote-mutating commands are never exposed here.
    module GitPanel
      module_function

      # Run a git subcommand in `dir` with argv-style args (no shell). Returns
      # [stdout, stderr, success_bool]. Never raises on git failure.
      def git(dir, *args)
        out, err, status = Open3.capture3("git", "-C", dir.to_s, *args)
        [out, err, status.success?]
      rescue StandardError => e
        ["", e.message, false]
      end

      # Whether `dir` is inside a git work tree.
      def repo?(dir)
        out, _err, ok = git(dir, "rev-parse", "--is-inside-work-tree")
        ok && out.strip == "true"
      end

      # { branch:, ahead:, behind:, files: [{ path:, x:, y:, staged:, untracked: }] }
      # Parsed from `git status --porcelain=v2 --branch`.
      def status(dir)
        out, _err, ok = git(dir, "status", "--porcelain=v2", "--branch")
        return { branch: nil, files: [] } unless ok

        branch = nil
        ahead = behind = 0
        files = []
        out.each_line do |line|
          line = line.chomp
          if line.start_with?("# branch.head ")
            branch = line.sub("# branch.head ", "")
          elsif line.start_with?("# branch.ab ")
            m = line.match(/\+(\d+) -(\d+)/)
            ahead, behind = m[1].to_i, m[2].to_i if m
          elsif line.start_with?("1 ", "2 ")
            xy = line.split(" ")[1]
            path = line.split(" ", 9).last
            files << { path: path, x: xy[0], y: xy[1],
                       staged: xy[0] != ".", untracked: false }
          elsif line.start_with?("? ")
            files << { path: line.sub("? ", ""), x: "?", y: "?",
                       staged: false, untracked: true }
          end
        end
        { branch: branch, ahead: ahead, behind: behind, files: files }
      end

      # Unified diff for one file, or the whole tree when `file` is nil.
      # Baseline is HEAD, not the index, so changes the agent staged with
      # `git add` still show up. Untracked files have no baseline at all, so
      # they diff against /dev/null via --no-index (rendered as pure
      # additions); the trailing `--` keeps a leading-dash filename from
      # being read as an option in that mode too.
      def diff(dir, file: nil)
        if file && !file.empty?
          others, _e, _ok = git(dir, "ls-files", "--others", "--exclude-standard", "--", file)
          if others.strip.empty?
            out, _e, _ok = git(dir, "diff", "HEAD", "--", file)
          else
            out, _e, _ok = git(dir, "diff", "--no-index", "--", "/dev/null", file)
          end
          out
        else
          git(dir, "diff", "HEAD")[0]
        end
      end

      # Recent commits: [{ hash:, short:, author:, date:, subject: }].
      def log(dir, limit: 50)
        limit = limit.to_i.clamp(1, 200)
        fmt = "%H%x1f%h%x1f%an%x1f%ad%x1f%s"
        out, _err, ok = git(dir, "log", "-n", limit.to_s, "--date=short", "--pretty=format:#{fmt}")
        return [] unless ok

        out.each_line.filter_map do |line|
          h, short, author, date, subject = line.chomp.split("\x1f")
          next unless h
          { hash: h, short: short, author: author, date: date, subject: subject }
        end
      end

      # [{ name:, current: bool }] from `git branch`.
      def branches(dir)
        out, _err, ok = git(dir, "branch", "--format=%(refname:short)%00%(HEAD)")
        return [] unless ok

        out.each_line.filter_map do |line|
          name, head = line.chomp.split("\x00")
          next unless name && !name.empty?
          { name: name, current: head == "*" }
        end
      end

      # Discard uncommitted changes to one file and return it to its HEAD
      # state (same baseline the diff API uses, so "what you saw is what you
      # lose"). Files that never existed in HEAD (staged-new or untracked)
      # have no earlier version, so they are removed instead. argv-only and
      # guarded against path traversal; history rewriting and remote-mutating
      # commands remain out of bounds.
      def restore(dir, file:)
        path = file.to_s.strip
        return { ok: false, error: "file is required" } if path.empty?
        return { ok: false, error: "invalid path" } if invalid_path?(path)

        head_tree, _e, _ok = git(dir, "ls-tree", "HEAD", "--", path)
        if head_tree.include?("\t#{path}")
          _o, err, ok = git(dir, "checkout", "HEAD", "--", path)
          return ok ? { ok: true } : { ok: false, error: "git checkout failed: #{err.strip}" }
        end

        in_index, _e, idx_ok = git(dir, "ls-files", "--", path)
        if idx_ok && !in_index.strip.empty?
          _o, err, ok = git(dir, "rm", "-f", "--", path)
          return ok ? { ok: true } : { ok: false, error: "git rm failed: #{err.strip}" }
        end

        target = File.expand_path(path, dir.to_s)
        root = File.expand_path(dir.to_s)
        return { ok: false, error: "invalid path" } unless target.start_with?(root + File::SEPARATOR)

        begin
          File.delete(target)
          { ok: true }
        rescue Errno::ENOENT
          { ok: true }
        rescue StandardError => e
          { ok: false, error: e.message }
        end
      end

      # Relative repo paths only: no absolute paths, no traversal segments.
      def invalid_path?(path)
        path.start_with?("/") || path.split("/").include?("..")
      end

      # Stage `files` (relative paths) and commit with `message`. Returns
      # { ok:, error?:, hash? }. Refuses empty message / empty file set. Uses
      # argv so paths/message cannot inject; no --no-verify, no amend.
      def commit(dir, message:, files:)
        msg   = message.to_s.strip
        paths = Array(files).map(&:to_s).reject(&:empty?)
        return { ok: false, error: "commit message is required" } if msg.empty?
        return { ok: false, error: "no files selected" } if paths.empty?

        _out, add_err, add_ok = git(dir, "add", "--", *paths)
        return { ok: false, error: "git add failed: #{add_err.strip}" } unless add_ok

        _out, c_err, c_ok = git(dir, "commit", "-m", msg, "--", *paths)
        return { ok: false, error: "git commit failed: #{c_err.strip}" } unless c_ok

        head, _err, _ok = git(dir, "rev-parse", "--short", "HEAD")
        { ok: true, hash: head.strip }
      end
    end
  end
end
