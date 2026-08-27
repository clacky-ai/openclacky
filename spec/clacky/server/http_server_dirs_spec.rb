# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"
require_relative "../../support/http_server_spec_helpers"

# Specs for the directory-picker mutation API:
#   GET     /api/dirs              (browse: now returns `default`)
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

  # ── GET /api/dirs returns `default` ───────────────────────────────────────

  describe "GET /api/dirs" do
    it "exposes default_working_dir as `default` so the picker can render the preset" do
      with_server(agent_config: agent_config) do |server|
        # Force a known default so we don't depend on the user's environment.
        custom_default = File.join(tmproot, "ws")
        FileUtils.mkdir_p(custom_default)
        allow(server).to receive(:default_working_dir).and_return(custom_default)

        req = fake_req(method: "GET", path: "/api/dirs",
                       query_string: "path=#{tmproot}")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body).to have_key("default")
        expect(body["default"]).to eq(custom_default)
        expect(body).to have_key("home")
        expect(body).to have_key("entries")
      end
    end

    it "exposes quick-access `places` as home favorites" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "GET", path: "/api/dirs",
                       query_string: "path=#{tmproot}")
        res = fake_res
        dispatch(server, req, res)

        expect(res.status).to eq(200)
        places = parsed_body(res)["places"]
        expect(places).to be_an(Array)

        home = places.find { |p| p["id"] == "home" }
        expect(home).not_to be_nil
        expect(home["path"]).to eq(Dir.home)
        expect(home["kind"]).to eq("favorite")

        # Only favorites are exposed; no root/locations/volumes.
        expect(places.map { |p| p["id"] }).not_to include("root", "applications")
        expect(places.map { |p| p["kind"] }.uniq).to eq(["favorite"])
      end
    end
  end

  # ── WSL quick-access mapping ─────────────────────────────────────────────
  # Under WSL every favorite (home/desktop/downloads/documents) must target the
  # Windows user profile (/mnt/<drive>/Users/<name>/...), not the Linux home.

  describe "WSL quick-access mapping" do
    it "targets the Windows profile for home/desktop/downloads/documents under WSL" do
      with_server(agent_config: agent_config) do |server|
        win_home = File.join(tmproot, "win")
        %w[Desktop Downloads Documents].each { |d| FileUtils.mkdir_p(File.join(win_home, d)) }
        allow(server).to receive(:wsl_windows_home).and_return(win_home)

        places = server.send(:dir_picker_places)

        expect(places.find { |p| p[:id] == "home" }[:path]).to eq(win_home)
        expect(places.find { |p| p[:id] == "desktop" }[:path]).to eq(File.join(win_home, "Desktop"))
        expect(places.find { |p| p[:id] == "downloads" }[:path]).to eq(File.join(win_home, "Downloads"))
        expect(places.find { |p| p[:id] == "documents" }[:path]).to eq(File.join(win_home, "Documents"))
      end
    end

    it "scans mounted drives for the single real profile, skipping system dirs" do
      with_server(agent_config: agent_config) do |server|
        allow(server).to receive(:wsl?).and_return(true)
        allow(ENV).to receive(:[]).and_wrap_original do |original, *args|
          %w[WINDOWS_USERNAME USERNAME].include?(args.first) ? nil : original.call(*args)
        end
        allow(Dir).to receive(:exist?).and_wrap_original do |original, *args|
          %w[/mnt /mnt/c/Users /mnt/d/Users].include?(args.first) ? true : original.call(*args)
        end
        allow(Dir).to receive(:children).and_wrap_original do |original, *args|
          case args.first
          when "/mnt" then ["c", "d"]
          when "/mnt/c/Users" then ["Public", "Default", "Default User", "All Users", "leo"]
          else original.call(*args)
          end
        end
        allow(File).to receive(:directory?).and_wrap_original do |original, *args|
          args.first == "/mnt/c/Users/leo" ? true : original.call(*args)
        end

        expect(server.send(:wsl_windows_home)).to eq("/mnt/c/Users/leo")
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
