# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer, "@file mention endpoints" do
  include HttpServerSpecHelpers

  let(:tmpdir)  { Dir.mktmpdir("clacky_files_spec") }
  let(:workdir) { File.join(tmpdir, "work") }
  let(:config_file) { File.join(tmpdir, "config.yml") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      { "model" => "test-model", "api_key" => "k",
        "base_url" => "https://example.invalid/v1", "type" => "default" }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  before do
    FileUtils.mkdir_p(File.join(workdir, "docs"))
    File.write(File.join(workdir, "README.md"), "hello readme")
    File.write(File.join(workdir, "notes for ai.txt"), "space file content")
    File.write(File.join(workdir, "docs", "spec.md"), "nested spec")
    FileUtils.mkdir_p(File.join(workdir, ".git"))
    FileUtils.mkdir_p(File.join(workdir, "node_modules"))
    # Symlink loop: must never be descended into by the fuzzy search.
    File.symlink(workdir, File.join(workdir, "docs", "loop"))
  end

  after { FileUtils.rm_rf(tmpdir) }

  # Stub the registry snapshot so api_list_files sees one session whose
  # working_dir is our tmp fixture (no disk-backed session needed).
  def with_files_server
    with_server(agent_config: agent_config) do |server|
      registry = server.instance_variable_get(:@registry)
      allow(registry).to receive(:snapshot).and_return({ working_dir: workdir })
      yield server
    end
  end

  def get_files(server, query)
    qs = "session_id=s1&query=#{URI.encode_www_form_component(query)}"
    req = fake_req(method: "GET", path: "/api/files", query_string: qs)
    res = fake_res
    dispatch(server, req, res)
    [res.status, parsed_body(res)]
  end

  describe "GET /api/files" do
    it "lists top-level entries, excluding hidden and vendored dirs" do
      with_files_server do |server|
        status, body = get_files(server, "")
        expect(status).to eq(200)
        paths = body["files"].map { |f| f["path"] }
        expect(paths).to include("README.md", "docs/")
        expect(paths).not_to include(".git/", "node_modules/")
      end
    end

    it "navigates subdirectories and filters by name prefix" do
      with_files_server do |server|
        _status, body = get_files(server, "docs/sp")
        expect(body["files"].map { |f| f["path"] }).to eq(["docs/spec.md"])
      end
    end

    it "rejects path traversal outside the working_dir" do
      with_files_server do |server|
        _status, body = get_files(server, "../../../etc/")
        expect(body["files"]).to eq([])
      end
    end

    it "treats a leading slash as the relative root, not an absolute path" do
      with_files_server do |server|
        # "@/" must degrade to the top-level listing with valid relative
        # refs — never emit "/README.md"-style paths that
        # resolve_mention_attachments cannot match.
        paths = get_files(server, "/")[1]["files"].map { |f| f["path"] }
        expect(paths).to include("README.md")
        expect(paths).to all(satisfy { |p| !p.start_with?("/") })
      end
    end

    it "refuses to list through a symlink whose target is outside the working_dir" do
      outside = File.join(tmpdir, "outside")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "secret.txt"), "top secret")
      File.symlink(outside, File.join(workdir, "link"))

      with_files_server do |server|
        expect(get_files(server, "link/")[1]["files"]).to eq([])
      end
    end

    it "terminates fuzzy search despite symlink loops" do
      with_files_server do |server|
        _status, body = get_files(server, "loop")
        expect(body["files"].map { |f| f["path"] }).to include("docs/loop/")
      end
    end

    it "returns 400 without session_id" do
      with_files_server do |server|
        req = fake_req(method: "GET", path: "/api/files", query_string: "")
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(400)
      end
    end
  end

  describe "#resolve_mention_attachments" do
    def resolve(server, content, existing = [])
      server.send(:resolve_mention_attachments, content, workdir, existing)
    end

    it "resolves an existing file into an attachment entry" do
      with_files_server do |server|
        out = resolve(server, "look at @README.md please")
        expect(out.size).to eq(1)
        expect(out.first["name"]).to eq("README.md")
        expect(out.first["path"]).to eq(File.join(workdir, "README.md"))
        expect(out.first["mentioned"]).to be(true)
      end
    end

    it "supports quoted paths with spaces" do
      with_files_server do |server|
        out = resolve(server, 'check @"notes for ai.txt"')
        expect(out.map { |f| f["name"] }).to eq(["notes for ai.txt"])
      end
    end

    it "leaves unknown mentions untouched" do
      with_files_server do |server|
        expect(resolve(server, "ping @kyle")).to eq([])
      end
    end

    it "refuses to resolve files outside the working_dir" do
      with_files_server do |server|
        File.write(File.join(tmpdir, "secret.txt"), "top secret")
        expect(resolve(server, "steal @../secret.txt")).to eq([])
      end
    end

    it "refuses to resolve through a symlink whose target is outside the working_dir" do
      outside = File.join(tmpdir, "outside")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "secret.txt"), "top secret")
      File.symlink(outside, File.join(workdir, "link"))

      with_files_server do |server|
        expect(resolve(server, "look at @link/secret.txt")).to eq([])
      end
    end

    # Boundary rule: an @ glued to an email-local-part character is part of
    # an address / identifier, not a mention. Without this, "foo@bar.com"
    # silently attaches a file named bar.com.
    it "does not treat email addresses as mentions" do
      with_files_server do |server|
        File.write(File.join(workdir, "bar.com"), "innocent file")
        expect(resolve(server, "email me at foo@bar.com please")).to eq([])
      end
    end

    it "does not resolve a mid-word @ mention" do
      with_files_server do |server|
        expect(resolve(server, "x@README.md")).to eq([])
      end
    end

    it "resolves a mention directly after CJK text (no space required)" do
      with_files_server do |server|
        out = resolve(server, "请看@README.md")
        expect(out.map { |f| f["name"] }).to eq(["README.md"])
      end
    end

    it "tags working-dir images with mime_type so they route to vision" do
      with_files_server do |server|
        File.binwrite(File.join(workdir, "shot.png"), "\x89PNG".b)
        out = resolve(server, "see @shot.png")
        expect(out.first["mime_type"]).to eq("image/png")
      end
    end

    it "also resolves binary documents (the files: pipeline parses them)" do
      with_files_server do |server|
        File.binwrite(File.join(workdir, "report.docx"), "PK\x03\x04".b)
        out = resolve(server, "read @report.docx")
        expect(out.map { |f| f["name"] }).to eq(["report.docx"])
      end
    end

    it "deduplicates repeated mentions and files already uploaded" do
      with_files_server do |server|
        uploaded = [{ "path" => File.join(workdir, "README.md"), "name" => "README.md" }]
        out = resolve(server, "a @README.md and @README.md and @docs/spec.md", uploaded)
        expect(out.map { |f| f["name"] }).to eq(["spec.md"])
      end
    end

    it "caps the number of mention attachments" do
      with_files_server do |server|
        8.times { |i| File.write(File.join(workdir, "f#{i}.txt"), "x") }
        content = (0...8).map { |i| "@f#{i}.txt" }.join(" ")
        expect(resolve(server, content).size).to eq(5)
      end
    end

    # A mention naming a file the user already attached (uploads live outside
    # the working_dir) must not create a duplicate attachment — it flags the
    # existing entry as "mentioned" so the agent hints the model about it.
    it "flags an already-attached file as mentioned instead of duplicating it" do
      with_files_server do |server|
        uploaded = [{ "path" => "/tmp/clacky-uploads/ab12_report.pdf", "name" => "report.pdf" }]
        out = resolve(server, "summarise @report.pdf", uploaded)
        expect(out).to eq([]) # no new attachment entry
        expect(uploaded.first["mentioned"]).to be(true)
      end
    end

    it "flags an attached image (no path, data-url) by name" do
      with_files_server do |server|
        uploaded = [{ "name" => "IMG_001.png", "data_url" => "data:image/png;base64,xx" }]
        out = resolve(server, "what is in @IMG_001.png", uploaded)
        expect(out).to eq([])
        expect(uploaded.first["mentioned"]).to be(true)
      end
    end

    it "does not flag an attachment whose name does not match the mention" do
      with_files_server do |server|
        uploaded = [{ "path" => "/tmp/clacky-uploads/ab12_other.pdf", "name" => "other.pdf" }]
        out = resolve(server, "see @report.pdf", uploaded)
        expect(out).to eq([])
        expect(uploaded.first).not_to have_key("mentioned")
      end
    end

    it "still resolves a working-dir file when an attachment shares the name" do
      with_files_server do |server|
        # working_dir wins: README.md exists on disk, so it resolves as a real
        # attachment even though an upload with the same name is present.
        uploaded = [{ "path" => "/tmp/clacky-uploads/zz_README.md", "name" => "README.md" }]
        out = resolve(server, "read @README.md", uploaded)
        expect(out.map { |f| f["path"] }).to eq([File.join(workdir, "README.md")])
      end
    end
  end
end
