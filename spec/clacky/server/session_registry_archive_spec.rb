# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Clacky::Server::SessionRegistry, "archived sessions" do
  let(:temp_dir) { Dir.mktmpdir("clacky_registry_archive_spec") }
  let(:manager)  { Clacky::SessionManager.new(sessions_dir: temp_dir) }
  let(:registry) { described_class.new(session_manager: manager, agent_config: Clacky::AgentConfig.new) }

  after { FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir) }

  # Write a session JSON directly so archived_at / pinned / updated_at are
  # exactly what the example needs.
  def write_session(id:, updated_at:, archived_at: nil, pinned: false, source: nil, project_id: nil)
    data = {
      session_id: id,
      name:       id,
      created_at: updated_at,
      updated_at: updated_at,
      pinned:     pinned,
      source:     source,
      project_id: project_id,
      messages:   []
    }
    data[:archived_at] = archived_at if archived_at
    File.write(File.join(temp_dir, manager.send(:generate_filename, id, updated_at)), JSON.generate(data))
  end

  def ids(rows)
    rows.map { |row| row[:id] }
  end

  it "hides archived sessions from the sidebar list" do
    write_session(id: "aaaaaaaa", updated_at: "2026-01-01T00:00:00Z")
    write_session(id: "bbbbbbbb", updated_at: "2026-02-01T00:00:00Z")
    write_session(id: "cccccccc", updated_at: "2026-03-01T00:00:00Z", archived_at: "2026-03-02T00:00:00Z")

    expect(ids(registry.list)).to contain_exactly("aaaaaaaa", "bbbbbbbb")
  end

  it "returns only archived sessions when the archive view asks for them" do
    write_session(id: "aaaaaaaa", updated_at: "2026-01-01T00:00:00Z")
    write_session(id: "cccccccc", updated_at: "2026-03-01T00:00:00Z", archived_at: "2026-03-02T00:00:00Z")

    rows = registry.list(archived: true)

    expect(ids(rows)).to eq(["cccccccc"])
    expect(rows.first[:archived_at]).to eq("2026-03-02T00:00:00Z")
  end

  it "keeps an archived pinned session out of the sidebar" do
    write_session(id: "aaaaaaaa", updated_at: "2026-01-01T00:00:00Z", pinned: true, archived_at: "2026-01-02T00:00:00Z")
    write_session(id: "bbbbbbbb", updated_at: "2026-02-01T00:00:00Z")

    expect(ids(registry.list)).to eq(["bbbbbbbb"])
    expect(ids(registry.list(archived: true))).to eq(["aaaaaaaa"])
  end

  it "paginates the archive by last activity, not by archived_at" do
    # archived_at is ordered opposite to updated_at on purpose: the cursor has
    # to follow the same key as the sidebar sort, or "load more" would skip and
    # repeat rows.
    write_session(id: "aaaaaaaa", updated_at: "2026-01-01T00:00:00Z", archived_at: "2026-06-01T00:00:00Z")
    write_session(id: "bbbbbbbb", updated_at: "2026-02-01T00:00:00Z", archived_at: "2026-05-01T00:00:00Z")

    expect(ids(registry.list(archived: true, before: "2026-02-01T00:00:00Z"))).to eq(["aaaaaaaa"])
  end

  it "counts archived sessions out of the folded sidebar groups" do
    write_session(id: "cron1", updated_at: "2026-01-01T00:00:00Z", source: "cron")
    write_session(id: "cron2", updated_at: "2026-02-01T00:00:00Z", source: "cron", archived_at: "2026-02-02T00:00:00Z")

    expect(registry.group_stats("cron")).to eq(count: 1, latest_updated_at: "2026-01-01T00:00:00Z")
  end

  it "returns archived and active sessions together when archived is nil" do
    write_session(id: "aaaaaaaa", updated_at: "2026-01-01T00:00:00Z")
    write_session(id: "bbbbbbbb", updated_at: "2026-02-01T00:00:00Z", archived_at: "2026-02-02T00:00:00Z")

    expect(ids(registry.list(archived: nil))).to contain_exactly("aaaaaaaa", "bbbbbbbb")
  end

  it "reports the total count of archived sessions across all groups" do
    write_session(id: "s1", updated_at: "2026-01-01T00:00:00Z", archived_at: "2026-01-02T00:00:00Z")
    write_session(id: "s2", updated_at: "2026-02-01T00:00:00Z")
    write_session(id: "s3", updated_at: "2026-03-01T00:00:00Z", archived_at: "2026-03-02T00:00:00Z")

    expect(registry.archived_count).to eq(2)
    expect(manager.archived_count).to eq(2)
  end
end
