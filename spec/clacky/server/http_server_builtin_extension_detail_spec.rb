# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"

RSpec.describe Clacky::Server::HttpServer, "builtin extension detail and assets" do
  let(:server) { described_class.allocate }
  let(:response) do
    Struct.new(:status, :body, :headers) do
      def initialize
        super(nil, nil, {})
      end

      def [](key)
        headers[key]
      end

      def []=(key, value)
        headers[key] = value
      end
    end.new
  end

  describe "GET /api/store/extension" do
    it "describes a builtin from its own manifest without asking the store" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "icon.svg"), "<svg/>")
        container = {
          ext_id: "git", layer: :builtin, dir: dir, name: "Git", version: "0.1.0",
          author: "OpenClacky", homepage: "https://www.openclacky.com", origin: "self",
          disabled: false,
          contributes: { "panels" => [{ "id" => "git", "view" => "panels/git/view.js" }] },
          raw: { "display_name_zh" => "Git 管理", "description" => "Changes panel", "icon" => "icon.svg" }
        }
        allow(server).to receive(:extension_container).with("git").and_return(container)
        expect(Clacky::BrandConfig).not_to receive(:load)

        payload = nil
        allow(server).to receive(:json_response) { |_res, _code, body| payload = body }

        server.send(:api_store_extension_detail, double("req", query: { "id" => "git" }), response)

        ext = payload[:extension]
        expect(payload[:ok]).to be(true)
        expect(ext["display_name_zh"]).to eq("Git 管理")
        expect(ext["layer"]).to eq("builtin")
        expect(ext["installed"]).to be(true)
        expect(ext["removable"]).to be(false)
        expect(ext["unlisted"]).to be(false)
        expect(ext["icon_url"]).to eq("/ext_ui/git/icon.svg")
        expect(ext["contributes"]).to include("panels")
      end
    end

    context "readme" do
      around do |example|
        Dir.mktmpdir do |dir|
          @dir = dir
          File.write(File.join(dir, "README.md"), "# English guide")
          File.write(File.join(dir, "README.zh.md"), "# 中文说明")
          example.run
        end
      ensure
        Thread.current[:lang] = nil
      end

      def detail_for(lang)
        Thread.current[:lang] = lang
        container = { ext_id: "git", layer: :builtin, dir: @dir, raw: {} }
        allow(server).to receive(:extension_container).with("git").and_return(container)
        payload = nil
        allow(server).to receive(:json_response) { |_res, _code, body| payload = body }
        server.send(:api_store_extension_detail, double("req", query: { "id" => "git" }), response)
        payload[:extension]["readme"]
      end

      it "serves README.zh.md to Chinese clients" do
        expect(detail_for("zh-CN")).to eq("# 中文说明")
      end

      it "serves README.md otherwise" do
        expect(detail_for("en")).to eq("# English guide")
      end

      it "falls back to the process locale when the client sends no language" do
        allow(Clacky::I18n).to receive(:locale).and_return("en")

        expect(detail_for(nil)).to eq("# English guide")
      end

      it "falls back to README.md when no Chinese readme exists" do
        File.delete(File.join(@dir, "README.zh.md"))

        expect(detail_for("zh")).to eq("# English guide")
      end
    end
  end

  describe "GET /ext_ui/<ext>/<file>" do
    before do
      @dir = Dir.mktmpdir
      File.write(File.join(@dir, "icon.svg"), "<svg id='x'/>")
      File.write(File.join(@dir, "handler.rb"), "puts 1")
      container = { ext_id: "git", layer: :builtin, dir: @dir }
      allow(Clacky::ExtensionLoader).to receive(:load_all)
        .and_return(Clacky::ExtensionLoader::Result.new(containers: { "git" => container }))
    end

    after { FileUtils.remove_entry(@dir) }

    def serve(path)
      server.send(:serve_ext_ui, double("req", path: path), response)
    end

    it "serves an svg icon with the right content type" do
      serve("/ext_ui/git/icon.svg")

      expect(response.status).to eq(200)
      expect(response["Content-Type"]).to eq("image/svg+xml")
      expect(response.body).to include("<svg")
    end

    it "still serves assets when the extension is switched off" do
      allow(Clacky::ExtensionLoader).to receive(:load_all).and_return(
        Clacky::ExtensionLoader::Result.new(
          containers: { "git" => { ext_id: "git", layer: :builtin, dir: @dir, disabled: true } }
        )
      )

      serve("/ext_ui/git/icon.svg")

      expect(response.status).to eq(200)
    end

    it "refuses files outside the asset whitelist" do
      serve("/ext_ui/git/handler.rb")

      expect(response.status).to eq(415)
    end

    it "refuses a path that escapes the container" do
      serve("/ext_ui/git/../../../etc/passwd")

      expect(response.status).to eq(404)
    end

    it "404s an unknown extension" do
      serve("/ext_ui/nope/icon.svg")

      expect(response.status).to eq(404)
    end
  end

  describe "shipped builtin icons" do
    %w[advisor git preview computer-use meeting time_machine].each do |id|
      it "declares an existing icon for #{id}" do
        dir      = File.join(Clacky::ExtensionLoader::BUILTIN_DIR, id)
        manifest = YAMLCompat.load_file(File.join(dir, "ext.yml"))
        icon     = manifest["icon"].to_s

        expect(icon).not_to be_empty
        expect(File.file?(File.join(dir, icon))).to be(true)
      end

      it "ships English and Chinese readmes for #{id}" do
        dir = File.join(Clacky::ExtensionLoader::BUILTIN_DIR, id)

        %w[README.md README.zh.md].each do |name|
          expect(File.read(File.join(dir, name)).strip).not_to be_empty
        end
      end
    end
  end
end
