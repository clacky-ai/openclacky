# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "open3"
require "cgi"
require "clacky/server/http_server"
require "clacky/agent_config"
require_relative "../../support/http_server_spec_helpers"

# The new-session branch picker reads the project work tree instead of a
# session, so these cover the project-scoped git endpoints: what the picker
# sees, and what a switch actually does to the directory.
RSpec.describe Clacky::Server::HttpServer, "project git endpoints" do
  include HttpServerSpecHelpers

  let(:tmproot)      { Dir.mktmpdir("clacky_project_git_spec") }
  let(:sessions_dir) { File.join(tmproot, "sessions") }
  let(:repo_dir)     { File.join(tmproot, "repo") }
  let(:plain_dir)    { File.join(tmproot, "plain") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      {
        "model"            => "test-model",
        "api_key"          => "sk-testkey1234567890abcd",
        "base_url"         => "https://api.example.com",
        "anthropic_format" => true,
        "type"             => "default"
      }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", File.join(tmproot, "config.yml"))
    cfg
  end

  before do
    FileUtils.mkdir_p(sessions_dir)
    FileUtils.mkdir_p(plain_dir)
    init_repo(repo_dir)
  end

  after { FileUtils.rm_rf(tmproot) }

  def init_repo(dir)
    FileUtils.mkdir_p(dir)
    git(dir, "init", "-q")
    git(dir, "config", "user.email", "spec@example.com")
    git(dir, "config", "user.name", "Spec")
    git(dir, "config", "gc.auto", "0")
    git(dir, "config", "maintenance.auto", "false")
    File.write(File.join(dir, "a.txt"), "one\n")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "init")
  end

  def git(dir, *args)
    Open3.capture3("git", "-C", dir, *args)
  end

  def current_branch(dir)
    Open3.capture3("git", "-C", dir, "symbolic-ref", "--short", "HEAD").first.strip
  end

  def create_project(server, name:, working_dir: nil)
    server.instance_variable_get(:@project_manager).create(name: name, working_dir: working_dir)
  end

  def git_info(server, project_id, dir: nil)
    res  = fake_res
    qs   = dir ? "dir=#{CGI.escape(dir)}" : ""
    req  = fake_req(method: "GET", path: "/api/projects/#{project_id}/git", query_string: qs)
    dispatch(server, req, res)
    [res.status, parsed_body(res)]
  end

  def checkout(server, project_id, body)
    res = fake_res
    dispatch(server, fake_req(method: "POST", path: "/api/projects/#{project_id}/git/checkout",
                              body: body), res)
    [res.status, parsed_body(res)]
  end

  it "reports the current branch and the branch list" do
    with_server(agent_config: agent_config, sessions_dir: sessions_dir) do |server|
      git(repo_dir, "branch", "other")
      project = create_project(server, name: "repo", working_dir: repo_dir)

      status, body = git_info(server, project[:id])

      expect(status).to eq(200)
      expect(body["repo"]).to be(true)
      expect(body["branch"]).to eq(current_branch(repo_dir))
      names = body["branches"].map { |b| b["name"] }
      expect(names).to include("other")
      expect(body["branches"].find { |b| b["current"] }["name"]).to eq(current_branch(repo_dir))
    end
  end

  it "reports repo: false for a project without a git work tree" do
    with_server(agent_config: agent_config, sessions_dir: sessions_dir) do |server|
      plain  = create_project(server, name: "plain", working_dir: plain_dir)
      bare   = create_project(server, name: "no-dir")

      expect(git_info(server, plain[:id])).to eq([200, { "repo" => false }])
      expect(git_info(server, bare[:id])).to eq([200, { "repo" => false }])
    end
  end

  it "switches the work tree to an existing branch" do
    with_server(agent_config: agent_config, sessions_dir: sessions_dir) do |server|
      base = current_branch(repo_dir)
      git(repo_dir, "branch", "other")
      project = create_project(server, name: "repo", working_dir: repo_dir)

      status, body = checkout(server, project[:id], { "branch" => "other" })

      expect(status).to eq(200), body.inspect
      expect(body["branch"]).to eq("other")
      expect(current_branch(repo_dir)).to eq("other")
      expect(body["branches"].find { |b| b["current"] }["name"]).to eq("other")
      expect(base).not_to eq("other")
    end
  end

  it "creates a branch when asked" do
    with_server(agent_config: agent_config, sessions_dir: sessions_dir) do |server|
      project = create_project(server, name: "repo", working_dir: repo_dir)

      status, body = checkout(server, project[:id], { "branch" => "feature/new", "create" => true })

      expect(status).to eq(200), body.inspect
      expect(body["branch"]).to eq("feature/new")
      expect(current_branch(repo_dir)).to eq("feature/new")
    end
  end

  it "rejects a branch name git would read as an option" do
    with_server(agent_config: agent_config, sessions_dir: sessions_dir) do |server|
      before = current_branch(repo_dir)
      project = create_project(server, name: "repo", working_dir: repo_dir)

      status, body = checkout(server, project[:id], { "branch" => "--orphan", "create" => true })

      expect(status).to eq(422)
      expect(body["error"]).to eq("invalid branch name")
      expect(current_branch(repo_dir)).to eq(before)
    end
  end

  it "returns 404 for an unknown project" do
    with_server(agent_config: agent_config, sessions_dir: sessions_dir) do |server|
      expect(git_info(server, "nope").first).to eq(404)
      expect(checkout(server, "nope", { "branch" => "main" }).first).to eq(404)
    end
  end

  context "with a session working dir other than the project's" do
    let(:other_repo) { File.join(tmproot, "other-repo") }

    before do
      init_repo(other_repo)
      git(other_repo, "branch", "other-only")
    end

    it "reports the branch state of the given dir" do
      with_server(agent_config: agent_config, sessions_dir: sessions_dir) do |server|
        project = create_project(server, name: "repo", working_dir: repo_dir)

        status, body = git_info(server, project[:id], dir: other_repo)

        expect(status).to eq(200)
        expect(body["repo"]).to be(true)
        expect(body["branch"]).to eq(current_branch(other_repo))
        expect(body["branches"].map { |b| b["name"] }).to include("other-only")
      end
    end

    it "reports repo: false when the dir is missing or not a repo" do
      with_server(agent_config: agent_config, sessions_dir: sessions_dir) do |server|
        project = create_project(server, name: "repo", working_dir: repo_dir)

        expect(git_info(server, project[:id], dir: plain_dir)).to eq([200, { "repo" => false }])
        expect(git_info(server, project[:id], dir: File.join(tmproot, "gone"))).to eq([200, { "repo" => false }])
      end
    end

    it "checks out inside the given dir and leaves the project dir alone" do
      with_server(agent_config: agent_config, sessions_dir: sessions_dir) do |server|
        project       = create_project(server, name: "repo", working_dir: repo_dir)
        project_branch = current_branch(repo_dir)

        status, body = checkout(server, project[:id],
                                { "branch" => "other-only", "dir" => other_repo })

        expect(status).to eq(200), body.inspect
        expect(body["branch"]).to eq("other-only")
        expect(current_branch(other_repo)).to eq("other-only")
        expect(current_branch(repo_dir)).to eq(project_branch)
      end
    end

    it "rejects a dir that is not a git repository" do
      with_server(agent_config: agent_config, sessions_dir: sessions_dir) do |server|
        project = create_project(server, name: "repo", working_dir: repo_dir)

        status, body = checkout(server, project[:id], { "branch" => "main", "dir" => plain_dir })

        expect(status).to eq(400)
        expect(body["error"]).to eq("Not a git repository")
      end
    end
  end
end
