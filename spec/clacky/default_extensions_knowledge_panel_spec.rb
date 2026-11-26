# frozen_string_literal: true

require "spec_helper"

KB_PANEL_EXT_DIR = File.expand_path("../../lib/clacky/default_extensions/knowledge", __dir__)
require File.join(KB_PANEL_EXT_DIR, "lib/knowledge")

RSpec.describe "Knowledge management (store writes + API)" do
  let(:root) { Dir.mktmpdir }
  let(:trash) { Dir.mktmpdir }
  let(:store) { Clacky::Knowledge.store }

  before { Clacky::Knowledge.root = root }
  after do
    Clacky::Knowledge.root = nil
    [root, trash].each { |d| FileUtils.remove_entry(d) if Dir.exist?(d) }
  end

  describe "Store#resolve" do
    it "accepts .md paths inside entries/ only" do
      expect(store.resolve("产品/青岚茶.md")).to eq(File.join(File.expand_path(root), "entries", "产品", "青岚茶.md"))
      ["../kb.yml", "../../etc/passwd.md", "/tmp/x.md", "a.txt", "", "entries/../../x.md"].each do |bad|
        expect { store.resolve(bad) }.to raise_error(Clacky::Knowledge::Store::PathError), bad
      end
    end
  end

  describe "Store#save" do
    it "creates entries/<folder>/<title>.md with frontmatter and de-duplicates names" do
      rel = store.save(folder: "青岚茶志/第一章", title: "起源", source: "手册 p.3", body: "清明前后采摘。\n")
      expect(rel).to eq("青岚茶志/第一章/起源.md")
      entry = store.load(rel)
      expect(entry.to_h).to include(title: "起源", folder: "青岚茶志/第一章", source: "手册 p.3")
      expect(entry.body.strip).to eq("清明前后采摘。")
      expect(File.read(store.resolve(rel))).to start_with("---\n")

      expect(store.save(folder: "青岚茶志/第一章", title: "起源", body: "x")).to eq("青岚茶志/第一章/起源-2.md")
      expect(store.save(title: "a/b:c", body: "x")).to eq("a-b-c.md")
      expect(store.save(folder: "../x/ .. /y:z", title: "t", body: "x")).to eq("x/y-z/t.md")
      expect(store.load("a-b-c.md").folder).to eq("")
    end

    it "updates in place, keeping hand-written frontmatter keys and dropping cleared / legacy ones" do
      FileUtils.mkdir_p(File.join(root, "entries"))
      File.write(File.join(root, "entries", "doc.md"), "---\nid: my-id\ntitle: Old\ncategory: C\nsource: S\n---\nold\n")
      store.save(rel: "doc.md", title: "New", source: "", body: "new")
      entry = store.load("doc.md")
      expect(entry.id).to eq("my-id")
      expect(entry.to_h).to include(title: "New", source: nil)
      expect(entry.body.strip).to eq("new")
      expect(File.read(store.resolve("doc.md"))).not_to include("category")
    end

    it "requires a title" do
      expect { store.save(title: "  ", body: "x") }.to raise_error(Clacky::Knowledge::Store::PathError)
    end

    it "is picked up by the search index right away" do
      store.save(folder: "产品", title: "青岚茶", body: "冲泡水温 95 度。")
      expect(Clacky::Knowledge.index.search("水温").map { |h| h.entry.title }).to eq(["青岚茶"])
    end
  end

  describe "Store#trash" do
    it "moves the file to the trash with a metadata sidecar and keeps its (now empty) folder" do
      rel = store.save(folder: "c", title: "t", body: "x")
      dest = store.trash(rel, trash_dir: trash)
      expect(File.exist?(store.resolve(rel))).to be false
      expect(store.folders).to eq(["c"])
      meta = JSON.parse(File.read("#{dest}.metadata.json"))
      expect(meta).to include("original_path" => store.resolve(rel), "deleted_by" => "knowledge_panel")
    end
  end

  describe "folders" do
    it "lists every folder (empty ones too), creates, renames, and rejects escapes" do
      store.save(folder: "书/第一章", title: "a", body: "x")
      expect(store.create_folder("书", "第二章")).to eq("书/第二章")
      expect(store.folders).to eq(%w[书 书/第一章 书/第二章])
      expect { store.create_folder("书", "第二章") }.to raise_error(Clacky::Knowledge::Store::PathError, "already exists")
      expect { store.create_folder("", "  ") }.to raise_error(Clacky::Knowledge::Store::PathError)
      expect { store.create_folder("../..", "x") }.to raise_error(Clacky::Knowledge::Store::PathError)

      expect(store.rename_folder("书", "青岚茶志")).to eq("青岚茶志")
      expect(store.entries.map(&:folder)).to eq(["青岚茶志/第一章"])
      expect { store.rename_folder("", "x") }.to raise_error(Clacky::Knowledge::Store::PathError)
      expect { store.rename_folder("nope", "x") }.to raise_error(Clacky::Knowledge::Store::PathError, "not found")
    end

    it "moves an entry between folders, de-duplicating the name" do
      a = store.save(folder: "书/第一章", title: "起源", body: "1")
      store.save(title: "起源", body: "2")
      expect(store.move(a, "")).to eq("起源-2.md")
      expect(store.move("起源.md", "书/第一章")).to eq("书/第一章/起源.md")
      expect(store.move("书/第一章/起源.md", "书/第一章")).to eq("书/第一章/起源.md")
      expect(store.entries.map { |e| store.relative(e.path) }).to contain_exactly("起源-2.md", "书/第一章/起源.md")
      expect(store.folders).to eq(%w[书 书/第一章])
    end

    it "trashes a whole folder" do
      store.save(folder: "书/第一章", title: "a", body: "x")
      dest = store.trash_folder("书", trash_dir: trash)
      expect(store.entries).to be_empty
      expect(store.folders).to be_empty
      expect(File.exist?(File.join(dest, "第一章", "a.md"))).to be true
      expect(JSON.parse(File.read("#{dest}.metadata.json"))).to include("file_type" => "directory")
      expect { store.trash_folder("", trash_dir: trash) }.to raise_error(Clacky::Knowledge::Store::PathError)
    end
  end

  describe "API handler" do
    let(:handler_class) do
      Clacky::ApiExtension.reset_registry!
      load(File.join(KB_PANEL_EXT_DIR, "api/handler.rb"), true)
      Clacky::ApiExtension.pending_subclasses.last
    end

    after { Clacky::ApiExtension.reset_registry! }

    def call(method, pattern, body: nil, query: {}, query_string: nil)
      route = handler_class.routes.find { |r| r.method == method && r.pattern == pattern }
      req = double("request", body: body && JSON.generate(body), query: query, query_string: query_string)
      handler_class.new(req: req, res: nil, route: route, params: {}, http_server: nil).invoke
      raise "handler did not respond"
    rescue Clacky::ApiExtension::Halt => halt
      [halt.status, JSON.parse(halt.payload)]
    end

    it "creates, lists, reads and updates entries" do
      status, data = call(:post, "/entry", body: { folder: "产品", title: "青岚茶", body: "清明采摘" })
      expect(status).to eq(200)
      path = data["entry"]["path"]
      expect(path).to eq("产品/青岚茶.md")

      _, list = call(:get, "/entries")
      expect(list).to include("enabled" => true, "folders" => ["产品"])
      expect(list["entries"].first).to include("path" => path, "title" => "青岚茶", "folder" => "产品", "chars" => 4)

      _, one = call(:get, "/entry", query: { "path" => path })
      expect(one["entry"]["body"]).to eq("清明采摘")

      call(:post, "/entry", body: { path: path, title: "青岚茶", body: "改过" })
      expect(store.load(path).body.strip).to eq("改过")
    end

    it "manages folders and moves entries" do
      expect(call(:post, "/folder", body: { parent: "", name: "书" })).to eq([200, { "ok" => true, "folder" => "书" }])
      expect(call(:post, "/folder", body: { parent: "书", name: "第一章" }).last["folder"]).to eq("书/第一章")
      expect(call(:post, "/folder", body: { parent: "书", name: "第一章" })).to eq([422, { "error" => "already exists" }])

      rel = store.save(title: "起源", body: "x")
      expect(call(:post, "/move", body: { path: rel, folder: "书/第一章" }).last["path"]).to eq("书/第一章/起源.md")
      expect(call(:post, "/folder/rename", body: { folder: "书", name: "青岚茶志" }).last["folder"]).to eq("青岚茶志")
      expect(store.load("青岚茶志/第一章/起源.md")).not_to be_nil

      fake = double("trash dir", trash_dir: trash)
      allow(Clacky::TrashDirectory).to receive(:new).with(File.expand_path(root)).and_return(fake)
      qs = URI.encode_www_form(folder: "青岚茶志")
      expect(call(:delete, "/folder", query: {}, query_string: qs).first).to eq(200)
      expect(store.entries).to be_empty
      expect(call(:delete, "/folder", query: {}, query_string: "folder=").first).to eq(422)
    end

    it "rejects paths outside entries/ with 422" do
      status, data = call(:get, "/entry", query: { "path" => "../kb.yml" })
      expect(status).to eq(422)
      expect(data["error"]).to match(/\.md|escapes/)
      expect(call(:post, "/entry", body: { path: "../../x.md", title: "x" }).first).to eq(422)
    end

    it "deletes into the trash, reading path from the raw query string (WEBrick leaves req.query empty on DELETE)" do
      rel = store.save(folder: "分类", title: "测试", body: "x")
      fake = double("trash dir", trash_dir: trash)
      allow(Clacky::TrashDirectory).to receive(:new).with(File.expand_path(root)).and_return(fake)
      qs = URI.encode_www_form(path: rel)
      expect(call(:delete, "/entry", query: {}, query_string: qs).first).to eq(200)
      expect(store.entries).to be_empty
      expect(Dir.glob(File.join(trash, "*.metadata.json")).size).to eq(1)
    end

    it "returns ranked hits with the injected top_k for test search" do
      store.save(folder: "产品", title: "青岚茶", body: "冲泡水温 95 度。")
      store.save(title: "门楼", body: "振成楼门楼建于 1912 年。")
      status, data = call(:post, "/search", body: { query: "水温多少" })
      expect(status).to eq(200)
      expect(data["top_k"]).to eq(5)
      expect(data["hits"].map { |h| h["title"] }).to eq(["青岚茶"])
      expect(data["hits"].first).to include("path" => "产品/青岚茶.md", "folder" => "产品")
    end

    def preview(name, data)
      file = data.b
      file.define_singleton_method(:filename) { name }
      route = handler_class.routes.find { |r| r.method == :post && r.pattern == "/preview" }
      req = double("request", body: nil, query: { "file" => file })
      handler_class.new(req: req, res: nil, route: route, params: {}, http_server: nil).invoke
      raise "handler did not respond"
    rescue Clacky::ApiExtension::Halt => halt
      [halt.status, JSON.parse(halt.payload)]
    end

    it "previews an uploaded markdown file without saving it, honouring its frontmatter" do
      status, data = preview("manual.md", "---\ntitle: 手册\nsource: 官网\n---\n正文")
      expect(status).to eq(200)
      expect(data).to include("title" => "手册", "source" => "官网", "parsed" => false)
      expect(data["body"].strip).to eq("正文")
      expect(store.entries).to be_empty
    end

    it "rejects unsupported and empty uploads" do
      expect(preview("a.exe", "x").first).to eq(415)
      expect(preview("a.md", "").first).to eq(422)
      expect(store.entries).to be_empty
    end

    it "falls back to the file name as the source when a text file has no frontmatter" do
      status, data = preview("须知.txt", "开放时间")
      expect(status).to eq(200)
      expect(data).to include("title" => "须知", "source" => "须知.txt", "parsed" => false)

      status, data = preview("manual.md", "正文")
      expect(status).to eq(200)
      expect(data).to include("title" => "manual", "source" => "manual.md", "parsed" => false)
    end

    it "previews parsed PDF / Word text with the file name as source" do
      allow(Clacky::Utils::ParserManager).to receive(:setup!)
      allow(Clacky::Utils::ParserManager).to receive(:parse)
        .and_return(success: true, text: "--- Page 1 ---\n第一页\n\n\n\n第二段")
      status, data = preview("手册.pdf", "%PDF-fake")
      expect(status).to eq(200)
      expect(data).to include("title" => "手册", "source" => "手册.pdf", "parsed" => true, "body" => "第一页\n\n第二段")
      expect(store.entries).to be_empty
    end

    def upload(name, data, folder: nil)
      file = data.b
      file.define_singleton_method(:filename) { name }
      query = { "file" => file }
      query["folder"] = folder.b if folder
      route = handler_class.routes.find { |r| r.method == :post && r.pattern == "/upload" }
      req = double("request", body: nil, query: query)
      handler_class.new(req: req, res: nil, route: route, params: {}, http_server: nil).invoke
      raise "handler did not respond"
    rescue Clacky::ApiExtension::Halt => halt
      [halt.status, JSON.parse(halt.payload)]
    end

    it "saves a folder-import upload straight away into its (nested) folder" do
      status, data = upload("起源.md", "清明采摘", folder: "青岚茶志/第一章")
      expect(status).to eq(200)
      expect(data["path"]).to eq("青岚茶志/第一章/起源.md")
      expect(store.load(data["path"]).to_h).to include(title: "起源", folder: "青岚茶志/第一章")
    end

    it "saves a folder-import upload with no folder at the top level" do
      status, data = upload("须知.txt", "开放时间", folder: "")
      expect(status).to eq(200)
      expect(data["path"]).to eq("须知.md")
      expect(store.load(data["path"]).to_h).to include(title: "须知", source: "须知.txt", folder: "")
    end

    it "rejects unsupported and empty folder-import uploads" do
      expect(upload("a.exe", "x").first).to eq(415)
      expect(upload("空.md", "")).to eq([422, { "error" => "empty file" }])
      expect(store.entries).to be_empty
    end
  end
end
