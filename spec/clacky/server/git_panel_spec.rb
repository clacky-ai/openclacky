# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "clacky/server/git_panel"

# git runs auto maintenance in a detached background process after commit. It
# keeps writing into .git while Dir.mktmpdir tears the repo down, which makes
# the teardown fail with ENOTEMPTY on the slower CI runners. Disable it per
# repo and retry the removal, so a stray background git cannot fail the suite.
module GitPanelRepo
  def init_repo(dir)
    @dir = dir
    run "git", "init", "-q"
    run "git", "config", "user.email", "spec@example.com"
    run "git", "config", "user.name", "Spec"
    run "git", "config", "gc.auto", "0"
    run "git", "config", "maintenance.auto", "false"
  end

  def remove_repo(dir)
    deadline = Time.now + 5
    begin
      FileUtils.remove_entry(dir)
    rescue SystemCallError
      raise if Time.now > deadline
      sleep 0.1
      retry
    end
  end
end

# Specs for GitPanel.diff - the endpoint behind the Changes panel's per-file
# diff view. The interesting cases are the baselines: diffs run against HEAD
# (not the index) so staged edits stay visible, and untracked files diff
# against /dev/null via --no-index so a brand-new file renders as additions.
RSpec.describe Clacky::Server::GitPanel, ".diff" do
  include GitPanelRepo

  around do |ex|
    dir = Dir.mktmpdir("git_panel_spec")
    begin
      init_repo(dir)
      ex.run
    ensure
      remove_repo(dir)
    end
  end

  def run(*args)
    out, _err, _st = Open3.capture3(*args.map(&:to_s), chdir: @dir)
    out
  end

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit_all(message)
    run "git", "add", "-A"
    run "git", "commit", "-q", "-m", message
  end

  it "returns empty for an unchanged tree" do
    write "a.txt", "one\n"
    commit_all "init"
    expect(described_class.diff(@dir)).to eq("")
  end

  it "shows modifications of a tracked file" do
    write "a.txt", "one\n"
    commit_all "init"
    write "a.txt", "one\ntwo\n"
    out = described_class.diff(@dir, file: "a.txt")
    expect(out).to include("+two")
    expect(out).not_to include("-two")
  end

  it "shows the full file as additions for an untracked file" do
    write "a.txt", "one\n"
    commit_all "init"
    write "new.rb", "puts 'hi'\n"
    out = described_class.diff(@dir, file: "new.rb")
    expect(out).to include("+puts 'hi'")
    expect(out).not_to include("-puts")
  end

  it "includes staged edits (baseline is HEAD, not the index)" do
    write "a.txt", "one\n"
    commit_all "init"
    write "a.txt", "one\ntwo\n"
    run "git", "add", "a.txt"
    out = described_class.diff(@dir, file: "a.txt")
    expect(out).to include("+two")
  end

  it "shows a deleted file as pure removals" do
    write "gone.txt", "bye\n"
    commit_all "init"
    File.delete(File.join(@dir, "gone.txt"))
    out = described_class.diff(@dir, file: "gone.txt")
    expect(out).to include("-bye")
  end

  it "does not treat a leading-dash filename as an option" do
    write "a.txt", "one\n"
    commit_all "init"
    write "-weird.txt", "content\n"
    out = described_class.diff(@dir, file: "-weird.txt")
    expect(out).to include("+content")
  end

  it "reports a binary file without a line-by-line diff" do
    write "a.bin", "\x00\x01\x02\x03"
    commit_all "init"
    write "a.bin", "\x00\x01\x02\x04"
    out = described_class.diff(@dir, file: "a.bin")
    expect(out).to match(/Binary files .* differ/)
  end

  it "keeps a non-ASCII filename readable in the diff header" do
    write "图片测试.jpg", "one\n"
    commit_all "init"
    write "图片测试.jpg", "one\ntwo\n"
    out = described_class.diff(@dir, file: "图片测试.jpg")
    expect(out).to include("a/图片测试.jpg")
    expect(out).to include("+two")
  end

  # The changes panel asks for a huge context value when the user clicks an
  # "N unmodified lines" gap, so the surrounding code has to come back.
  it "widens the context window when context: is given" do
    lines = (1..40).map { |i| "line#{format('%02d', i)}\n" }.join
    write "a.txt", lines
    commit_all "init"
    write "a.txt", lines.sub("line20\n", "line20 changed\n")

    narrow = described_class.diff(@dir, file: "a.txt")
    expect(narrow).not_to include("line01")

    wide = described_class.diff(@dir, file: "a.txt", context: 999_999)
    expect(wide).to include("line01")
    expect(wide).to include("+line20 changed")
    expect(wide).to include("line40")
  end

  it "clamps an absurd context value instead of passing it through" do
    write "a.txt", "one\n"
    commit_all "init"
    write "a.txt", "one\ntwo\n"
    expect(described_class.diff(@dir, file: "a.txt", context: 10**12)).to include("+two")
  end

  it "drops context entirely when context: 0" do
    write "a.txt", "one\ntwo\nthree\n"
    commit_all "init"
    write "a.txt", "one\nTWO\nthree\n"
    out = described_class.diff(@dir, file: "a.txt", context: 0)
    expect(out).to include("@@ -2 +2 @@")
    expect(out.lines.grep(/\A /)).to be_empty
  end
end

# Specs for GitPanel.status - the file list behind the Changes panel. git
# octal-escapes non-ASCII paths unless core.quotePath is off, which would
# surface as unreadable names in the panel.
RSpec.describe Clacky::Server::GitPanel, ".status" do
  include GitPanelRepo

  around do |ex|
    dir = Dir.mktmpdir("git_panel_status_spec")
    begin
      init_repo(dir)
      ex.run
    ensure
      remove_repo(dir)
    end
  end

  def run(*args)
    out, _err, _st = Open3.capture3(*args.map(&:to_s), chdir: @dir)
    out
  end

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit_all(message)
    run "git", "add", "-A"
    run "git", "commit", "-q", "-m", message
  end

  it "lists non-ASCII paths verbatim for tracked and untracked files" do
    write "图片测试.jpg", "one\n"
    commit_all "init"
    write "图片测试.jpg", "one\ntwo\n"
    write "新增 未跟踪.png", "x\n"

    files = described_class.status(@dir)[:files]
    paths = files.map { |f| f[:path] }
    expect(paths).to include("图片测试.jpg")
    expect(paths).to include("新增 未跟踪.png")
    expect(files.find { |f| f[:path] == "新增 未跟踪.png" }[:untracked]).to be_truthy
  end
end

RSpec.describe Clacky::Server::GitPanel, ".restore" do
  include GitPanelRepo

  around do |ex|
    dir = Dir.mktmpdir("git_panel_restore_spec")
    begin
      init_repo(dir)
      ex.run
    ensure
      remove_repo(dir)
    end
  end

  def run(*args)
    out, _err, _st = Open3.capture3(*args.map(&:to_s), chdir: @dir)
    out
  end

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit_all(message)
    run "git", "add", "-A"
    run "git", "commit", "-q", "-m", message
  end

  def read(path)
    File.read(File.join(@dir, path))
  end

  def exists?(path)
    File.exist?(File.join(@dir, path))
  end

  it "returns a tracked modified file to its HEAD content" do
    write "a.txt", "one\n"
    commit_all "init"
    write "a.txt", "one\ntwo\n"
    result = described_class.restore(@dir, file: "a.txt")
    expect(result[:ok]).to be_truthy
    expect(read("a.txt")).to eq("one\n")
  end

  it "clears staged edits too (baseline is HEAD, not the index)" do
    write "a.txt", "one\n"
    commit_all "init"
    write "a.txt", "one\ntwo\n"
    run "git", "add", "a.txt"
    result = described_class.restore(@dir, file: "a.txt")
    expect(result[:ok]).to be_truthy
    expect(read("a.txt")).to eq("one\n")
    expect(run("git", "status", "--porcelain")).to be_empty
  end

  it "brings back a tracked file that was deleted" do
    write "gone.txt", "bye\n"
    commit_all "init"
    File.delete(File.join(@dir, "gone.txt"))
    result = described_class.restore(@dir, file: "gone.txt")
    expect(result[:ok]).to be_truthy
    expect(read("gone.txt")).to eq("bye\n")
  end

  it "deletes an untracked file" do
    write "a.txt", "one\n"
    commit_all "init"
    write "new.rb", "puts 'hi'\n"
    result = described_class.restore(@dir, file: "new.rb")
    expect(result[:ok]).to be_truthy
    expect(exists?("new.rb")).to be_falsey
    expect(run("git", "status", "--porcelain")).to be_empty
  end

  it "drops a staged new file from both the index and the worktree" do
    write "a.txt", "one\n"
    commit_all "init"
    write "new.rb", "puts 'hi'\n"
    run "git", "add", "new.rb"
    result = described_class.restore(@dir, file: "new.rb")
    expect(result[:ok]).to be_truthy
    expect(exists?("new.rb")).to be_falsey
    expect(run("git", "status", "--porcelain")).to be_empty
  end

  it "refuses traversal paths" do
    write "a.txt", "one\n"
    commit_all "init"
    expect(described_class.restore(@dir, file: "../a.txt")[:ok]).to be_falsey
    expect(described_class.restore(@dir, file: "/etc/passwd")[:ok]).to be_falsey
    expect(exists?("../a.txt")).to be_falsey
  end

  it "refuses an empty file" do
    expect(described_class.restore(@dir, file: "")[:ok]).to be_falsey
    expect(described_class.restore(@dir, file: nil)[:ok]).to be_falsey
  end

  # Octal-escaped ls-tree output used to make the HEAD lookup miss, so a
  # committed file with a non-ASCII name fell through to the `git rm` branch
  # and was deleted instead of restored.
  it "restores a tracked non-ASCII filename instead of deleting it" do
    write "图片测试.jpg", "one\n"
    commit_all "init"
    write "图片测试.jpg", "one\ntwo\n"
    result = described_class.restore(@dir, file: "图片测试.jpg")
    expect(result[:ok]).to be_truthy
    expect(exists?("图片测试.jpg")).to be_truthy
    expect(read("图片测试.jpg")).to eq("one\n")
  end

  it "deletes an untracked non-ASCII filename" do
    write "a.txt", "one\n"
    commit_all "init"
    write "新增 未跟踪.png", "x\n"
    result = described_class.restore(@dir, file: "新增 未跟踪.png")
    expect(result[:ok]).to be_truthy
    expect(exists?("新增 未跟踪.png")).to be_falsey
  end
end

# Specs for GitPanel.review - the single payload behind the Changes panel.
# One `git diff HEAD` is split into per-file chunks so a tree full of edits
# costs one subprocess; untracked files have no baseline and are diffed
# against /dev/null separately. Line counts drive the +/- badges.
RSpec.describe Clacky::Server::GitPanel, ".log" do
  include GitPanelRepo

  around do |ex|
    dir = Dir.mktmpdir("git_panel_log_spec")
    begin
      init_repo(dir)
      ex.run
    ensure
      remove_repo(dir)
    end
  end

  def run(*args)
    out, _err, _st = Open3.capture3(*args.map(&:to_s), chdir: @dir)
    out
  end

  def write(path, content)
    File.write(File.join(@dir, path), content)
  end

  def commit_all(message)
    run "git", "add", "-A"
    run "git", "commit", "-q", "-m", message
  end

  # The default base is resolved from the upstream first; a hand-written
  # remote-tracking ref keeps the spec independent of any real remote.
  def fake_remote_pointing_at_head
    run "git", "update-ref", "refs/remotes/origin/main", run("git", "rev-parse", "HEAD").strip
  end

  it "lists recent commits newest first" do
    write "a.txt", "one\n"
    commit_all "init"
    write "a.txt", "two\n"
    commit_all "second"

    expect(described_class.log(@dir).map { |c| c[:subject] }).to eq(%w[second init])
  end

  it "keeps every commit when unpushed is not requested" do
    write "a.txt", "one\n"
    commit_all "init"
    fake_remote_pointing_at_head
    write "a.txt", "two\n"
    commit_all "local only"

    expect(described_class.log(@dir).size).to eq(2)
  end

  it "limits the log to commits the remote does not have when unpushed" do
    write "a.txt", "one\n"
    commit_all "init"
    fake_remote_pointing_at_head
    write "a.txt", "two\n"
    commit_all "local only"

    expect(described_class.log(@dir, unpushed: true).map { |c| c[:subject] }).to eq(["local only"])
  end

  it "returns nothing when every commit is already on the remote" do
    write "a.txt", "one\n"
    commit_all "init"
    fake_remote_pointing_at_head

    expect(described_class.log(@dir, unpushed: true)).to eq([])
  end
end

RSpec.describe Clacky::Server::GitPanel, ".review" do
  include GitPanelRepo

  around do |ex|
    dir = Dir.mktmpdir("git_panel_review_spec")
    begin
      init_repo(dir)
      ex.run
    ensure
      remove_repo(dir)
    end
  end

  def run(*args)
    out, _err, _st = Open3.capture3(*args.map(&:to_s), chdir: @dir)
    out
  end

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit_all(message)
    run "git", "add", "-A"
    run "git", "commit", "-q", "-m", message
  end

  it "reports repo: false outside a work tree" do
    outside = Dir.mktmpdir("git_panel_bare_spec")
    begin
      expect(described_class.review(outside)).to eq(repo: false)
    ensure
      FileUtils.remove_entry(outside)
    end
  end

  it "returns an empty file list for a clean tree" do
    write "a.txt", "one\n"
    commit_all "init"
    data = described_class.review(@dir)
    expect(data[:repo]).to be_truthy
    expect(data[:files]).to eq([])
    expect(data[:add]).to eq(0)
    expect(data[:del]).to eq(0)
  end

  it "carries the branch name and per-file counts" do
    write "a.txt", "one\n"
    commit_all "init"
    write "a.txt", "one\ntwo\nthree\n"
    file = described_class.review(@dir)[:files].first
    expect(file[:path]).to eq("a.txt")
    expect(file[:add]).to eq(2)
    expect(file[:del]).to eq(0)
    expect(file[:diff]).to include("+two")
    expect(described_class.review(@dir)[:branch]).not_to be_nil
  end

  it "splits a multi-file diff into one entry per file" do
    write "a.txt", "one\n"
    write "b.txt", "one\n"
    commit_all "init"
    write "a.txt", "one\na\n"
    write "b.txt", "one\nb\n"
    data = described_class.review(@dir)
    paths = data[:files].map { |f| f[:path] }
    expect(paths).to contain_exactly("a.txt", "b.txt")
    expect(data[:add]).to eq(2)
    expect(data[:files].find { |f| f[:path] == "a.txt" }[:diff]).not_to include("+b")
  end

  it "shows an untracked file as pure additions" do
    write "a.txt", "one\n"
    commit_all "init"
    write "dir/new.rb", "puts 'hi'\n"
    file = described_class.review(@dir)[:files].find { |f| f[:path] == "dir/new.rb" }
    expect(file[:untracked]).to be_truthy
    expect(file[:add]).to eq(1)
    expect(file[:del]).to eq(0)
    expect(file[:diff]).to include("+puts 'hi'")
  end

  it "counts removals for a deleted file" do
    write "gone.txt", "bye\n"
    commit_all "init"
    File.delete(File.join(@dir, "gone.txt"))
    file = described_class.review(@dir)[:files].first
    expect(file[:del]).to eq(1)
    expect(file[:diff]).to include("-bye")
  end

  it "flags a binary file instead of emitting a line diff" do
    write "a.bin", "\x00\x01\x02\x03"
    commit_all "init"
    write "a.bin", "\x00\x01\x02\x04"
    file = described_class.review(@dir)[:files].first
    expect(file[:binary]).to be_truthy
    expect(file[:add]).to eq(0)
    expect(file[:del]).to eq(0)
  end

  it "truncates a huge diff and says so" do
    write "big.txt", (1..500).map { |i| "line#{i}\n" }.join
    commit_all "init"
    write "big.txt", (1..500).map { |i| "changed#{i}\n" }.join
    file = described_class.review(@dir, max_lines: 40)[:files].first
    expect(file[:truncated]).to be_truthy
    expect(file[:diff].lines.size).to eq(40)
  end

  it "keeps a non-ASCII path readable" do
    write "图片测试.jpg", "one\n"
    commit_all "init"
    write "图片测试.jpg", "one\ntwo\n"
    file = described_class.review(@dir)[:files].first
    expect(file[:path]).to eq("图片测试.jpg")
    expect(file[:add]).to eq(1)
  end

  it "includes staged edits (baseline is HEAD)" do
    write "a.txt", "one\n"
    commit_all "init"
    write "a.txt", "one\ntwo\n"
    run "git", "add", "a.txt"
    file = described_class.review(@dir)[:files].first
    expect(file[:diff]).to include("+two")
  end

  it "limits the 'unstaged' scope to worktree edits outside the index" do
    write "a.txt", "one\n"
    commit_all "init"
    write "a.txt", "one\nstaged\n"
    run "git", "add", "a.txt"
    write "a.txt", "one\nstaged\nunstaged\n"

    data = described_class.review(@dir, scope: "unstaged")
    expect(data[:scope]).to eq("unstaged")
    expect(data[:files].map { |f| f[:path] }).to eq(["a.txt"])
    expect(data[:files].first[:diff]).to include("+unstaged")
    expect(data[:files].first[:diff]).not_to include("+staged")
  end

  it "limits the 'staged' scope to the index" do
    write "a.txt", "one\n"
    commit_all "init"
    write "a.txt", "one\nstaged\n"
    run "git", "add", "a.txt"
    write "a.txt", "one\nstaged\nunstaged\n"

    data = described_class.review(@dir, scope: "staged")
    expect(data[:files].map { |f| f[:path] }).to eq(["a.txt"])
    expect(data[:files].first[:diff]).to include("+staged")
    expect(data[:files].first[:diff]).not_to include("+unstaged")
  end

  it "compares the current branch against a base for 'branch'" do
    write "a.txt", "one\n"
    commit_all "init"
    base = run("git", "rev-parse", "--abbrev-ref", "HEAD").strip
    run "git", "checkout", "-q", "-b", "feature"
    write "b.txt", "b\n"
    commit_all "feature commit"

    data = described_class.review(@dir, scope: "branch", base: base)
    expect(data[:base]).to eq(base)
    expect(data[:files].map { |f| f[:path] }).to eq(["b.txt"])
    expect(data[:files].first[:x]).to eq("A")
    expect(data[:add]).to eq(1)
  end

  it "reports note: noBase when the base ref does not exist" do
    write "a.txt", "one\n"
    commit_all "init"
    data = described_class.review(@dir, scope: "branch", base: "no-such-branch")
    expect(data[:files]).to eq([])
    expect(data[:note]).to eq("noBase")
  end

  it "falls back to the default base when 'committed' gets none" do
    write "a.txt", "one\n"
    commit_all "init"
    branch = run("git", "rev-parse", "--abbrev-ref", "HEAD").strip
    data = described_class.review(@dir, scope: "committed")
    expect(data[:base]).to eq(branch)
  end

  it "falls back to the default base when 'branch' gets none" do
    write "a.txt", "one\n"
    commit_all "init"
    branch = run("git", "rev-parse", "--abbrev-ref", "HEAD").strip
    data = described_class.review(@dir, scope: "branch")
    expect(data[:base]).to eq(branch)
  end

  it "reviews the picked commit against its parent" do
    write "a.txt", "one\n"
    commit_all "init"
    write "b.txt", "b\n"
    commit_all "second"
    second = run("git", "rev-parse", "HEAD").strip

    data = described_class.review(@dir, scope: "committed", base: second)
    expect(data[:commit]).to eq(second)
    expect(data[:files].map { |f| f[:path] }).to eq(["b.txt"])
    expect(data[:files].first[:x]).to eq("A")
  end

  it "reviews a root commit against the empty tree" do
    write "a.txt", "one\n"
    commit_all "init"
    root = run("git", "rev-parse", "HEAD").strip
    write "b.txt", "b\n"
    commit_all "second"

    data = described_class.review(@dir, scope: "committed", base: root)
    expect(data[:files].map { |f| f[:path] }).to eq(["a.txt"])
    expect(data[:add]).to eq(1)
  end

  describe "payload budget" do
    it "drops the diff of files past the budget but keeps their counts" do
      write "a.txt", "one\ntwo\nthree\n"
      write "b.txt", "alpha\nbeta\ngamma\n"
      write "c.txt", "x\ny\nz\n"
      commit_all "init"
      write "a.txt", "one\ntwo\nthree\nfour\n"
      write "b.txt", "alpha\nbeta\ngamma\ndelta\n"
      write "c.txt", "x\ny\nz\nw\n"

      data = described_class.review(@dir, scope: "worktree", max_total_lines: 10)
      lazy = data[:files].select { |f| f[:lazy] }
      expect(lazy).not_to be_empty
      expect(lazy.map { |f| f[:diff] }).to all(eq(""))
      expect(lazy.map { |f| f[:add] }).to all(be >= 1)
      expect(data[:add]).to eq(3)
    end
  end

  describe "last turn" do
    it "reports note: noTurn when there is no previous turn" do
      agent = double("agent", get_task_history: [])
      data = described_class.last_turn_review(agent)
      expect(data[:files]).to eq([])
      expect(data[:note]).to eq("noTurn")
    end

    it "replays the previous task's snapshots" do
      agent = double(
        "agent",
        get_task_history: [{ task_id: 2, parent_task_id: 1, status: :current }],
        task_diff_files: [{ path: "app.rb", status: "modified", binary: false }],
        task_file_diff: { path: "app.rb", patch: "@@ -1 +1 @@\n-old\n+new\n", binary: false }
      )
      data = described_class.last_turn_review(agent)
      expect(data[:scope]).to eq("lastTurn")
      expect(data[:files].map { |f| f[:path] }).to eq(["app.rb"])
      expect(data[:add]).to eq(1)
      expect(data[:del]).to eq(1)
    end
  end
end

# The branch picker on the new-session page switches the project work tree, so
# these specs cover the two ways it can go wrong: a name git would read as an
# option, and a switch git refuses because of uncommitted work.
RSpec.describe Clacky::Server::GitPanel, ".checkout" do
  include GitPanelRepo

  around do |ex|
    dir = Dir.mktmpdir("git_panel_checkout_spec")
    begin
      init_repo(dir)
      ex.run
    ensure
      remove_repo(dir)
    end
  end

  def run(*args)
    out, _err, _st = Open3.capture3(*args.map(&:to_s), chdir: @dir)
    out
  end

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit_all(message)
    run "git", "add", "-A"
    run "git", "commit", "-q", "-m", message
  end

  def current
    run("git", "symbolic-ref", "--short", "HEAD").strip
  end

  before do
    write "a.txt", "one\n"
    commit_all "init"
  end

  it "creates a branch off HEAD and switches to it" do
    result = described_class.checkout(@dir, branch: "feature/x", create: true)

    expect(result).to eq(ok: true, branch: "feature/x")
    expect(current).to eq("feature/x")
  end

  it "switches to an existing branch" do
    base = current
    run "git", "branch", "other"

    result = described_class.checkout(@dir, branch: "other")

    expect(result[:ok]).to be_truthy
    expect(current).to eq("other")
    expect(described_class.branch_name(@dir)).to eq("other")
    expect(described_class.status(@dir)[:branch]).to eq("other")
    expect(base).not_to eq("other")
  end

  it "branches off an explicit base ref" do
    base = current
    run "git", "checkout", "-q", "-b", "side"
    write "a.txt", "side\n"
    commit_all "side"
    run "git", "checkout", "-q", base

    result = described_class.checkout(@dir, branch: "from-side", create: true, from: "side")

    expect(result[:ok]).to be_truthy
    expect(File.read(File.join(@dir, "a.txt"))).to eq("side\n")
  end

  it "refuses a name that would be parsed as an option" do
    before_name = current

    result = described_class.checkout(@dir, branch: "--orphan", create: true)

    expect(result[:ok]).to be(false)
    expect(result[:error]).to eq("invalid branch name")
    expect(current).to eq(before_name)
  end

  it "refuses an invalid base ref" do
    result = described_class.checkout(@dir, branch: "feature", create: true, from: "-x")

    expect(result[:ok]).to be(false)
    expect(result[:error]).to eq("invalid base ref")
  end

  it "passes git's own refusal through when uncommitted work blocks the switch" do
    base = current
    run "git", "checkout", "-q", "-b", "conflict"
    write "a.txt", "conflict\n"
    commit_all "conflict"
    run "git", "checkout", "-q", base
    write "a.txt", "uncommitted\n"

    result = described_class.checkout(@dir, branch: "conflict")

    expect(result[:ok]).to be(false)
    expect(result[:error]).to match(/local changes|would be overwritten/i)
    expect(current).to eq(base)
  end

  describe ".branch_name" do
    it "returns nil for a detached HEAD" do
      head = run("git", "rev-parse", "HEAD").strip
      run "git", "checkout", "-q", "--detach", head

      expect(described_class.branch_name(@dir)).to be_nil
    end
  end
end
