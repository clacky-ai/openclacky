# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "clacky/server/git_panel"

# Specs for GitPanel.diff - the endpoint behind the Changes panel's per-file
# diff view. The interesting cases are the baselines: diffs run against HEAD
# (not the index) so staged edits stay visible, and untracked files diff
# against /dev/null via --no-index so a brand-new file renders as additions.
RSpec.describe Clacky::Server::GitPanel, ".diff" do
  around do |ex|
    Dir.mktmpdir("git_panel_spec") do |dir|
      @dir = dir
      run "git", "init", "-q"
      run "git", "config", "user.email", "spec@example.com"
      run "git", "config", "user.name", "Spec"
      ex.run
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
end

RSpec.describe Clacky::Server::GitPanel, ".restore" do
  around do |ex|
    Dir.mktmpdir("git_panel_restore_spec") do |dir|
      @dir = dir
      run "git", "init", "-q"
      run "git", "config", "user.email", "spec@example.com"
      run "git", "config", "user.name", "Spec"
      ex.run
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
end
