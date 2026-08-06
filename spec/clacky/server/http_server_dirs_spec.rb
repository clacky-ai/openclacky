# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"
require_relative "http_server_spec"  # reuse HttpServerSpecHelpers

# Specs for the directory-picker mutation API:
#   GET     /api/dirs              (browse: returns `default` and picker context)
#   POST    /api/dirs/mkdir
#
# Directory rename was intentionally removed from the picker — see the
# "PATCH /api/dirs/rename (removed)" group below. Directory deletion was
# likewise removed — see the "DELETE /api/dirs/delete (removed)" group at
# the bottom of this file.
#
# These endpoints back the path picker used by the New Session modal and
# the Settings → Media Output Directory selector.
RSpec.describe Clacky::Server::HttpServer, "directory picker mutation API" do
  include HttpServerSpecHelpers

  let(:tmproot)     { Dir.mktmpdir("clacky_dirs_spec") }
  let(:config_file) { File.join(tmproot, "config.yml") }

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
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  after { FileUtils.rm_rf(tmproot) }

  # ── GET /api/dirs returns defaults and picker context ─────────────────────

  describe "GET /api/dirs" do
    it "exposes default_working_dir as `default` so the picker can render the preset" do
      with_server(agent_config: agent_config) do |server|
        # Force a known default so we don't depend on the user's environment.
        custom_default = File.join(tmproot, "ws")
        FileUtils.mkdir_p(custom_default)
        allow(server).to receive(:default_working_dir).and_return(custom_default)
        picker_context = {
          os: "macos",
          home: tmproot,
          picker_home: tmproot,
          desktop: File.join(tmproot, "Desktop")
        }
        allow(Clacky::Utils::EnvironmentDetector)
          .to receive(:directory_picker_context).and_return(picker_context)

        req = fake_req(method: "GET", path: "/api/dirs",
                       query_string: "path=#{tmproot}")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body).to have_key("default")
        expect(body["default"]).to eq(custom_default)
        expect(body).to have_key("home")
        expect(body["picker"]).to eq(JSON.parse(JSON.generate(picker_context)))
        expect(body).to have_key("entries")
      end
    end

    it "starts from the OS-friendly picker home when no path is provided" do
      with_server(agent_config: agent_config) do |server|
        picker_home = File.join(tmproot, "friendly-home")
        FileUtils.mkdir_p(picker_home)
        allow(Clacky::Utils::EnvironmentDetector)
          .to receive(:directory_picker_context).and_return(
            os: "wsl",
            home: "/home/tester",
            picker_home: picker_home,
            desktop: File.join(picker_home, "Desktop")
          )

        req = fake_req(method: "GET", path: "/api/dirs")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        expect(parsed_body(res)["root"]).to eq(picker_home)
      end
    end
  end

  # ── POST /api/dirs/mkdir ──────────────────────────────────────────────────

  describe "POST /api/dirs/mkdir" do
    it "creates a directory under an existing absolute parent" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/dirs/mkdir",
                       body: { parent: tmproot, name: "fresh" })
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body["ok"]).to be true
        expect(body["name"]).to eq("fresh")
        expect(Dir.exist?(File.join(tmproot, "fresh"))).to be true
      end
    end

    it "rejects a non-absolute parent" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/dirs/mkdir",
                       body: { parent: "relative/path", name: "x" })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(422)
      end
    end

    it "rejects names containing a backslash" do
      with_server(agent_config: agent_config) do |server|
        bs = 92.chr
        req = fake_req(method: "POST", path: "/api/dirs/mkdir",
                       body: { parent: tmproot, name: "a#{bs}b" })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(422)
      end
    end

    it "rejects names containing slashes" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/dirs/mkdir",
                       body: { parent: tmproot, name: "a/b" })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(422)
      end
    end

    it "rejects '.' and '..'" do
      with_server(agent_config: agent_config) do |server|
        %w[. ..].each do |bad|
          req = fake_req(method: "POST", path: "/api/dirs/mkdir",
                         body: { parent: tmproot, name: bad })
          res = fake_res
          dispatch(server, req, res)
          expect(res.status).to eq(422), "expected 422 for name=#{bad.inspect}"
        end
      end
    end

    it "404s when the parent does not exist" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "POST", path: "/api/dirs/mkdir",
                       body: { parent: File.join(tmproot, "nope"), name: "x" })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(404)
      end
    end

    it "422s when the target directory already exists" do
      with_server(agent_config: agent_config) do |server|
        FileUtils.mkdir_p(File.join(tmproot, "dup"))
        req = fake_req(method: "POST", path: "/api/dirs/mkdir",
                       body: { parent: tmproot, name: "dup" })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(422)
      end
    end
  end

  # ── PATCH /api/dirs/rename is intentionally NOT exposed ──────────────────
  # Directory rename was removed from the picker — too dangerous for a
  # one-click UI affordance (renaming an in-use workspace mid-session can
  # break tasks, sessions, MCP configs, …). This spec locks that decision
  # in: any PATCH on /api/dirs/rename must not actually rename anything.

  describe "PATCH /api/dirs/rename (removed)" do
    it "is not routed — handler must not run" do
      with_server(agent_config: agent_config) do |server|
        old_dir = File.join(tmproot, "stay")
        FileUtils.mkdir_p(old_dir)

        req = fake_req(method: "PATCH", path: "/api/dirs/rename",
                       body: { path: old_dir, new_name: "moved" })
        res = fake_res
        dispatch(server, req, res)

        # The route is gone; the dispatcher should fall through. Whatever
        # the exact status, the dir must still exist under its original
        # name — nothing should have been renamed.
        expect(Dir.exist?(old_dir)).to be true
        expect(Dir.exist?(File.join(tmproot, "moved"))).to be false
        expect(res.status).not_to eq(200)
      end
    end
  end

  # ── DELETE /api/dirs/delete is intentionally NOT exposed ──────────────────
  # Directory deletion was removed from the picker — too dangerous for a
  # one-click UI affordance, even with a trash bucket. This spec locks
  # that decision in: any DELETE on /api/dirs/delete should fall through
  # the route table and not return 200/4xx-from-our-handler.

  describe "DELETE /api/dirs/delete (removed)" do
    it "is not routed — handler must not run" do
      with_server(agent_config: agent_config) do |server|
        target = File.join(tmproot, "still_here")
        FileUtils.mkdir_p(target)

        req = fake_req(method: "DELETE", path: "/api/dirs/delete",
                       body: { path: target })
        res = fake_res
        dispatch(server, req, res)

        # The route is gone; the dispatcher should fall through to its
        # default 404 handler. Whatever the exact status, the dir must
        # still exist on disk — our handler is the only thing that ever
        # mv'd it to trash.
        expect(Dir.exist?(target)).to be true
        expect(res.status).not_to eq(200)
      end
    end
  end
end
