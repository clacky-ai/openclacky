# frozen_string_literal: true
require "spec_helper"
require "clacky/server/http_server"
require "zip"
require "stringio"
require_relative "../../support/http_server_spec_helpers"

RSpec.describe "Work debug export" do
  include HttpServerSpecHelpers
  let(:dir) { Dir.mktmpdir("work-export") }
  let(:manager) { Clacky::SessionManager.new(sessions_dir: dir) }
  let(:store) { Clacky::Work::Store.new(File.join(dir, "work", "state.json")) }
  let(:service) do
    Clacky::Work::Service.new(store: store, registry: nil, build_session: nil,
                             submit_task: nil, interrupt: nil, persist: nil)
  end
  let(:server) do
    Clacky::Server::HttpServer.allocate.tap do |server|
      server.instance_variable_set(:@session_manager, manager)
      server.instance_variable_set(:@work_service, service)
    end
  end
  before do
    %w[owner worker other sibling plain].each do |id|
      manager.save(session_id: id, created_at: "2026-11-05T00:00:00Z", messages: [{ role: "user", content: id }])
    end
    store.transaction do |data|
      data["cards"] = {
        "work_1" => { "id" => "work_1", "owner_session_id" => "owner", "session_id" => "worker", "revision" => 2, "outbox" => [] },
        "work_2" => { "id" => "work_2", "owner_session_id" => "other", "session_id" => "sibling", "outbox" => [] }
      }
      data["events"] = [{ "id" => "event_1", "work_id" => "work_1" }, { "id" => "private_event", "work_id" => "work_2" }]
    end
    allow(Clacky::Logger).to receive(:current_log_file).and_return(nil)
  end
  after { FileUtils.rm_rf(dir) }

  def export(id)
    response = fake_res
    server.api_export_session(id, response)
    expect(response.status).to eq(200), response.body
    result = {}
    Zip::InputStream.open(StringIO.new(response.body)) do |zip|
      while (entry = zip.get_next_entry)
        result[entry.name] = zip.read
      end
    end
    result
  end

  it "includes only owned work, worker history/chunks and matched events" do
    bundle = manager.files_for("worker")
    chunk = bundle[:json_path].sub(/\.json$/, "-chunk-1.md")
    File.write(chunk, "archived worker history")
    files = export("own") # Resolve a user-supplied prefix before looking up work.
    expect(JSON.parse(files.fetch("session.json"))["session_id"]).to eq("owner")
    expect(files.fetch("work/sessions/worker/#{File.basename(chunk)}")).to eq("archived worker history")
    expect(JSON.parse(files.fetch("work/cards.json")).map { |card| card["id"] }).to eq(["work_1"])
    expect(JSON.parse(files.fetch("work/events.json"))).to eq([{ "id" => "event_1", "work_id" => "work_1" }])
    expect(files.keys).not_to include("work/sessions/sibling/session.json")
    manifest = JSON.parse(files.fetch("work/manifest.json"))
    expect(manifest["sessions"]).to eq([{ "session_id" => "worker", "path" => "work/sessions/worker/session.json", "status" => "included" }])
  end

  it "exports a worker with its card without expanding to its owner or siblings" do
    files = export("worker")
    expect(files.keys.grep(%r{work/sessions/})).to be_empty
    expect(JSON.parse(files.fetch("work/manifest.json"))["sessions"].first).to include("path" => "session.json")
    expect(JSON.parse(files.fetch("work/cards.json")).first["owner_session_id"]).to eq("owner")
  end

  it "records a missing worker instead of failing the download" do
    File.unlink(manager.files_for("worker")[:json_path])
    files = export("owner")
    expect(JSON.parse(files.fetch("work/manifest.json"))["sessions"]).to eq([{ "session_id" => "worker", "status" => "missing" }])
  end

  it "leaves ordinary session exports unchanged" do
    expect(export("plain").keys).to eq(["session.json"])
  end
end
