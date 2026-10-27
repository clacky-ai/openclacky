# frozen_string_literal: true

require "open3"

require_relative "../utils/encoding"

module Clacky
  module Server
    # Read-mostly git operations scoped to a session's working directory, backing
    # the official "git" WebUI panel. Commands run with explicit argv (no shell),
    # so user-supplied values (paths, messages) cannot inject. The only write
    # operation is a single-file `restore`; committing is left to the agent, and
    # history-rewriting / remote-mutating commands are never exposed here.
    module GitPanel
      module_function

      # Whole-payload diff budget. A branch comparison against a long-lived
      # branch can be 900 files / 200k lines; serialising that and building the
      # DOM for it locks up the browser, so files past this budget are returned
      # without their diff and the UI loads them on demand.
      DEFAULT_MAX_TOTAL_LINES = 12_000

      # Run a git subcommand in `dir` with argv-style args (no shell). Returns
      # [stdout, stderr, success_bool]. Never raises on git failure.
      #
      # `core.quotePath=false` keeps git from octal-escaping non-ASCII paths, so
      # the parsers below (and the path comparisons in `restore`) see the same
      # bytes the caller passed in. Output is then normalised to UTF-8 because
      # git inherits the locale, and under a non-UTF-8 locale the raw bytes come
      # back tagged US-ASCII, where String#split would raise on multibyte paths.
      def git(dir, *args)
        out, err, status = Open3.capture3("git", "-C", dir.to_s, "-c", "core.quotePath=false", *args)
        [Utils::Encoding.to_utf8(out), Utils::Encoding.to_utf8(err), status.success?]
      rescue StandardError => e
        ["", e.message, false]
      end

      # Whether `dir` is inside a git work tree.
      def repo?(dir)
        out, _err, ok = git(dir, "rev-parse", "--is-inside-work-tree")
        ok && out.strip == "true"
      end

      # { branch:, ahead:, behind:, files: [{ path:, x:, y:, staged:, untracked: }] }
      # Parsed from `git status --porcelain=v2 --branch`. Untracked files are
      # listed individually (`--untracked-files=all`): the default collapses a
      # new directory into one `dir/` entry, which the panel cannot diff.
      def status(dir)
        out, _err, ok = git(dir, "status", "--porcelain=v2", "--branch", "--untracked-files=all")
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
      # `context` overrides the default three lines of surrounding code; the
      # changes panel passes a huge value to reveal the whole file behind a
      # collapsed "N unmodified lines" gap.
      def diff(dir, file: nil, context: nil, scope: "worktree", base: nil)
        extra = context ? ["-U#{context.to_i.clamp(0, 1_000_000).to_s}"] : []
        range = diff_range(dir, scope, base)
        if file && !file.empty?
          others, _e, _ok = git(dir, "ls-files", "--others", "--exclude-standard", "--", file)
          if others.strip.empty?
            out, _e, _ok = git(dir, "diff", *range, *extra, "--", file)
          elsif scope.to_s == "worktree" || scope.to_s == "unstaged"
            out, _e, _ok = git(dir, "diff", "--no-index", *extra, "--", "/dev/null", file)
          else
            out = ""
          end
          out
        else
          git(dir, "diff", *range, *extra)[0]
        end
      end

      # Baseline args for `git diff` in the given scope. `worktree` keeps the
      # historical behaviour (HEAD); `committed`/`branch` compare the merge
      # base of the chosen branch so unrelated commits on it do not leak in.
      def diff_range(dir, scope, base)
        case scope.to_s
        when "unstaged" then []
        when "staged" then ["--cached", "HEAD"]
        when "committed", "branch"
          base_ref = base.to_s.strip
          base_ref = default_base(dir) if base_ref.empty? && scope.to_s == "committed"
          ref?(dir, base_ref) ? ["#{base_ref}...HEAD"] : []
        else ["HEAD"]
        end
      end

      # Review scopes, mirroring the selector above the changes panel:
      #   worktree  - everything not committed yet (baseline HEAD)
      #   unstaged  - index vs working tree
      #   staged    - HEAD vs index
      #   committed - the branch's commits on top of its base (upstream)
      #   branch    - the same comparison against a branch the user picked
      #   lastTurn  - what the previous agent turn touched (served from the
      #               Time Machine snapshots by `last_turn_review`, not git)
      SCOPES = %w[worktree unstaged staged committed branch lastTurn].freeze

      # One payload for the whole changes panel: status order, per-file unified
      # diff, and per-file added/removed line counts. Tracked changes come from
      # a single diff split on its `diff --git` headers so N files cost one
      # subprocess; untracked files have no baseline and are diffed against
      # /dev/null individually (they are usually few).
      #
      # `max_lines` caps each file's diff so a minified bundle cannot stall the
      # browser; `truncated` tells the UI to say so instead of rendering half a
      # hunk silently.
      def review(dir, max_lines: 4000, max_total_lines: DEFAULT_MAX_TOTAL_LINES, scope: nil, base: nil)
        return { repo: false } unless repo?(dir)

        scope = SCOPES.include?(scope.to_s) ? scope.to_s : "worktree"
        st = status(dir)
        payload = { repo: true, branch: st[:branch], ahead: st[:ahead],
                    behind: st[:behind], scope: scope }

        case scope
        when "unstaged"
          payload.merge!(unstaged_review(dir, st, max_lines: max_lines))
        when "staged"
          payload.merge!(range_review(dir, ["--cached", "HEAD"], max_lines: max_lines,
                                      max_total_lines: max_total_lines))
        when "committed", "branch"
          base_ref = base.to_s.strip
          base_ref = default_base(dir) if base_ref.empty? && scope == "committed"
          if base_ref.empty? || !ref?(dir, base_ref)
            payload.merge!(files: [], add: 0, del: 0, note: "noBase")
          else
            payload[:base] = base_ref
            payload.merge!(range_review(dir, ["#{base_ref}...HEAD"], max_lines: max_lines,
                                        max_total_lines: max_total_lines))
          end
        else
          payload.merge!(worktree_review(dir, st, max_lines: max_lines,
                                         max_total_lines: max_total_lines))
        end
      end

      def worktree_review(dir, st, max_lines:, max_total_lines: DEFAULT_MAX_TOTAL_LINES)
        chunks = split_diff(git(dir, "diff", "HEAD")[0])
        entries_review(st[:files], max_lines: max_lines, max_total_lines: max_total_lines) do |f|
          f[:untracked] ? diff(dir, file: f[:path]) : (chunks[f[:path]] || diff(dir, file: f[:path]))
        end
      end

      def unstaged_review(dir, st, max_lines:, max_total_lines: DEFAULT_MAX_TOTAL_LINES)
        chunks = split_diff(git(dir, "diff")[0])
        subset = st[:files].select { |f| f[:untracked] || f[:y].to_s != "." }
        entries_review(subset, max_lines: max_lines, max_total_lines: max_total_lines) do |f|
          f[:untracked] ? diff(dir, file: f[:path]) : chunks[f[:path]].to_s
        end
      end

      def range_review(dir, range_args, max_lines:, max_total_lines: DEFAULT_MAX_TOTAL_LINES)
        chunks = split_diff(git(dir, "diff", *range_args)[0])
        files = chunks.map do |path, text|
          build_file(path, text, max_lines: max_lines,
                     x: diff_letter(text), y: ".")
        end
        totals(budget_files(files, max_total_lines))
      end

      def entries_review(entries, max_lines:, max_total_lines: DEFAULT_MAX_TOTAL_LINES)
        files = entries.map do |f|
          text = yield(f).to_s
          build_file(f[:path], text, max_lines: max_lines,
                     x: f[:x], y: f[:y], untracked: f[:untracked])
        end
        totals(budget_files(files, max_total_lines))
      end

      # A branch comparison can span hundreds of files and hundreds of
      # thousands of lines. Shipping every diff as JSON freezes the browser
      # while it builds that much DOM, so files past the budget lose their
      # `diff` payload and are flagged `lazy` — the UI fetches them one at a
      # time when the user actually opens one. Counts stay intact so the tree
      # still shows accurate +/- badges.
      def budget_files(files, max_total_lines)
        remaining = max_total_lines.to_i
        files.each do |f|
          if remaining <= 0
            f[:lazy] = true
            f[:diff] = ""
          else
            remaining -= f[:diff].lines.size
          end
        end
        files
      end

      def build_file(path, text, max_lines:, x: "M", y: ".", untracked: false, binary: nil)
        text, truncated = trim_diff(text.to_s, max_lines)
        add, del = count_changes(text)
        { path: path, x: x, y: y, untracked: untracked,
          add: add, del: del, truncated: truncated,
          binary: binary.nil? ? text.match?(/^Binary files .* differ$/) : binary,
          diff: text }
      end

      def totals(files)
        { files: files,
          add: files.sum { |f| f[:add] },
          del: files.sum { |f| f[:del] } }
      end

      # A file added or removed between the two sides of a diff has no content
      # on one of them; the UI uses the letter for its A/D/M tag.
      def diff_letter(text)
        return "A" if text.match?(/^new file mode /)
        return "D" if text.match?(/^deleted file mode /)
        "M"
      end

      # Upstream of the current branch is the natural base for "committed":
      # it is exactly the commits that have not been pushed yet. Falling back
      # to origin/HEAD and then a local main/master covers fresh clones and
      # branches without an upstream.
      def default_base(dir)
        out, _err, ok = git(dir, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
        return out.strip if ok && !out.strip.empty?

        out, _err, ok = git(dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
        return out.strip if ok && !out.strip.empty?

        %w[origin/main origin/master main master].find { |name| ref?(dir, name) }.to_s
      end

      def ref?(dir, name)
        return false if name.to_s.empty? || name.start_with?("-")

        _out, _err, ok = git(dir, "rev-parse", "--verify", "--quiet", "#{name}^{commit}")
        ok
      end

      # Scope "lastTurn": what the previous agent turn changed. Git has no
      # notion of a turn, so this comes from Time Machine snapshots — each task
      # keeps a BEFORE/AFTER tree of the files it touched.
      def last_turn_review(agent, max_lines: 4000, max_total_lines: DEFAULT_MAX_TOTAL_LINES)
        payload = { repo: true, scope: "lastTurn", files: [], add: 0, del: 0, note: "noTurn" }
        return payload unless agent.respond_to?(:get_task_history)

        history = agent.get_task_history(limit: 20)
        current = history.find { |task| task[:status] == :current }
        task_id = current ? current[:parent_task_id].to_i : 0
        return payload if task_id <= 0

        files = agent.task_diff_files(task_id).map do |entry|
          detail = agent.task_file_diff(task_id, entry[:path]) || {}
          build_file(entry[:path], detail[:patch].to_s, max_lines: max_lines,
                     x: { "added" => "A", "deleted" => "D" }.fetch(entry[:status], "M"),
                     y: ".", binary: detail[:binary] ? true : nil)
        end
        totals(budget_files(files, max_total_lines)).merge(repo: true, scope: "lastTurn", task_id: task_id)
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

      # [{ name:, current: bool, remote: bool }] from `git branch --all`.
      # Remote HEAD pointers (`origin/HEAD` → `origin/main`) are dropped: they
      # are aliases, not branches the user can compare against.
      def branches(dir)
        out, _err, ok = git(dir, "branch", "--all",
                            "--format=%(refname)%00%(refname:short)%00%(HEAD)")
        return [] unless ok

        out.each_line.filter_map do |line|
          full, name, head = line.chomp.split("\x00")
          next unless full && name && !name.empty?
          next if full.end_with?("/HEAD")
          { name: name, current: head == "*", remote: full.start_with?("refs/remotes/") }
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

      # Split a multi-file `git diff` into { path => chunk } keyed by the repo
      # path, preferring the `+++ b/` side (the `--- a/` side is
      # `/dev/null` for added files).
      def split_diff(text)
        chunks = {}
        path = nil
        buf = []
        flush = lambda do
          chunks[path] = buf.join if path && !buf.empty?
        end
        text.each_line do |line|
          if line.start_with?("diff --git ")
            flush.call
            buf = [line]
            path = nil
          else
            buf << line
            next if path
            if line.start_with?("--- a/")
              path = line.sub("--- a/", "").chomp
            elsif line.start_with?("+++ b/")
              path = line.sub("+++ b/", "").chomp
            end
          end
        end
        flush.call
        chunks
      end

      def count_changes(text)
        add = 0
        del = 0
        text.each_line do |line|
          next if line.start_with?("+++", "---")
          if line.start_with?("+")
            add += 1
          elsif line.start_with?("-")
            del += 1
          end
        end
        [add, del]
      end

      def trim_diff(text, max_lines)
        lines = text.lines
        return [text, false] if lines.size <= max_lines
        [lines.first(max_lines).join, true]
      end

      # Relative repo paths only: no absolute paths, no traversal segments.
      def invalid_path?(path)
        path.start_with?("/") || path.split("/").include?("..")
      end
    end
  end
end
