# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "uri"
require_relative "../lib/knowledge"
require_relative "../lib/importer"

# Knowledge management API — backs the sidebar "Knowledge Base" page.
# Mounted at /api/ext/knowledge/. Entries are addressed by `path`, relative
# to entries/ (e.g. "青岚茶志/第一章/起源.md"); folders by their relative
# path ("" = top level). Folders are the user-facing structure (any depth).
class KnowledgeExt < Clacky::ApiExtension
  timeout 15

  # GET /api/ext/knowledge/entries
  get "/entries" do
    store = Clacky::Knowledge.store
    store.ensure_dirs!
    entries = store.entries.map do |e|
      {
        path: store.relative(e.path), id: e.id, title: e.title,
        folder: e.folder, source: e.source, chars: e.body.strip.length,
        updated_at: File.mtime(e.path).utc.iso8601
      }
    end
    json(
      root: store.root,
      enabled: store.enabled?,
      switched_off: store.config["enabled"] == false,
      folders: store.folders,
      entries: entries
    )
  end

  # GET /api/ext/knowledge/entry?path=
  get "/entry" do
    entry = with_store { |s| s.load(path_param) }
    error!("not found", status: 404) unless entry
    json(entry: entry_json(entry))
  end

  # POST /api/ext/knowledge/entry  body: { path?, folder?, title, source?, body }
  # No path → create in `folder`; path → overwrite that entry in place.
  post "/entry" do
    b = json_body
    rel = with_store do |s|
      s.save(rel: b["path"], folder: b["folder"], title: b["title"], source: b["source"], body: b["body"])
    end
    json(ok: true, entry: entry_json(Clacky::Knowledge.store.load(rel)))
  end

  # POST /api/ext/knowledge/move  body: { path, folder }
  post "/move" do
    b = json_body
    rel = with_store { |s| s.move(b["path"], b["folder"]) }
    json(ok: true, path: rel)
  end

  # POST /api/ext/knowledge/folder  body: { parent?, name }
  post "/folder" do
    b = json_body
    rel = with_store { |s| s.create_folder(b["parent"], b["name"]) }
    json(ok: true, folder: rel)
  end

  # POST /api/ext/knowledge/folder/rename  body: { folder, name }
  post "/folder/rename" do
    b = json_body
    rel = with_store { |s| s.rename_folder(b["folder"], b["name"]) }
    json(ok: true, folder: rel)
  end

  # DELETE /api/ext/knowledge/folder?folder=   (whole folder → ~/.clacky/trash)
  delete "/folder" do
    with_store do |s|
      s.trash_folder(query_value("folder"), trash_dir: Clacky::TrashDirectory.new(s.root).trash_dir)
    end
    json(ok: true)
  end

  # DELETE /api/ext/knowledge/entry?path=   (moved to ~/.clacky/trash)
  delete "/entry" do
    with_store do |s|
      s.trash(path_param, trash_dir: Clacky::TrashDirectory.new(s.root).trash_dir)
    end
    json(ok: true)
  end

  # POST /api/ext/knowledge/preview   multipart: file
  # Converts one uploaded file to entry fields WITHOUT saving (PDF / Word are
  # parsed to text). The panel shows it for review, then saves via POST /entry.
  post "/preview", timeout: 120 do
    fields = with_upload { |importer, path, filename| importer.read_file(path, filename: filename) }
    json(ok: true, **fields)
  end

  # POST /api/ext/knowledge/upload   multipart: file, folder?
  # Saves one file straight away — used by folder import, where the browser
  # reads the folder on the user's machine and sends supported files one by
  # one, each with the folder it should land in (sub-folders are kept).
  post "/upload", timeout: 120 do
    folder = form_text("folder")
    rel = with_upload { |importer, path, filename| importer.import_file(path, filename: filename, folder: folder) }
    json(ok: true, path: rel)
  end

  # POST /api/ext/knowledge/search  body: { query, limit? }
  # Same BM25 index the agent uses — shows what a question would retrieve.
  post "/search" do
    q = json_body["query"].to_s.strip
    error!("query required", status: 422) if q.empty?
    limit = json_body["limit"].to_i
    limit = Clacky::Knowledge.top_k if limit <= 0
    store = Clacky::Knowledge.store
    hits = Clacky::Knowledge.index.search(q, limit: [limit, 20].min)
    json(
      top_k: Clacky::Knowledge.top_k,
      hits: hits.map do |h|
        { path: store.relative(h.entry.path), title: h.entry.title, folder: h.entry.folder,
          source: h.entry.source, score: h.score.round(3), text: Clacky::Knowledge.snippet(h.text) }
      end
    )
  end

  # WEBrick only parses the query string into req.query for GET/HEAD, so a
  # DELETE ?path= arrives empty there; fall back to the raw query string.
  private def path_param
    query_value("path")
  end

  private def query_value(name)
    query[name] || URI.decode_www_form(req.query_string.to_s).to_h[name]
  end

  private def with_store
    yield Clacky::Knowledge.store
  rescue Clacky::Knowledge::Store::PathError => e
    error!(e.message, status: 422)
  end

  # Write the multipart "file" field to a temp path and yield
  # (importer, path, filename); the temp file is gone afterwards.
  private def with_upload
    upload = req.query["file"]
    error!("missing file", status: 422) unless upload
    filename = upload.respond_to?(:filename) && upload.filename ? upload.filename.to_s : "upload.txt"
    filename = File.basename(filename.dup.force_encoding("UTF-8").scrub(""))
    data = upload.to_s
    store = Clacky::Knowledge.store
    store.ensure_dirs!
    importer = Clacky::Knowledge::Importer.new(store)
    Dir.mktmpdir("clacky-kb-upload") do |dir|
      path = File.join(dir, "upload#{File.extname(filename).downcase}")
      File.binwrite(path, data)
      yield importer, path, filename
    end
  rescue Clacky::Knowledge::Importer::UnsupportedError => e
    error!(e.message, status: 415)
  rescue Clacky::Knowledge::Importer::ImportError, Clacky::Knowledge::Store::PathError => e
    error!(e.message, status: 422)
  end

  # Plain-text multipart field (UTF-8), blank → nil.
  private def form_text(name)
    v = req.query[name].to_s.dup.force_encoding("UTF-8").scrub("").strip
    v.empty? ? nil : v
  end

  private def entry_json(entry)
    store = Clacky::Knowledge.store
    {
      path: store.relative(entry.path), id: entry.id, title: entry.title,
      folder: entry.folder, source: entry.source, body: entry.body.strip,
      updated_at: File.mtime(entry.path).utc.iso8601
    }
  end
end
