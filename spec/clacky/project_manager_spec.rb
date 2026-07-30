# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "clacky/project_manager"

RSpec.describe Clacky::ProjectManager do
  let(:tmpdir) { Dir.mktmpdir("clacky_project_manager") }
  let(:file_path) { File.join(tmpdir, "projects.json") }
  let(:manager) { described_class.new(file_path: file_path) }
  let(:project_dir) { File.join(tmpdir, "app") }

  before { FileUtils.mkdir_p(project_dir) }
  after { FileUtils.rm_rf(tmpdir) }

  it "opens a new project for an existing directory" do
    project = manager.open(project_dir)

    expect(project[:id]).to be_a(String)
    expect(project[:id].length).to eq(32)
    expect(project[:name]).to eq("app")
    expect(project[:path]).to eq(File.realpath(project_dir))
    expect(manager.list.map { |p| p[:id] }).to eq([project[:id]])
  end

  it "reuses the same project when opening the same path again" do
    first = manager.open(project_dir, name: "Demo")
    second = manager.open(project_dir)

    expect(second[:id]).to eq(first[:id])
    expect(second[:name]).to eq("Demo")
    expect(manager.list.size).to eq(1)
  end

  it "lists projects most-recently-opened first" do
    older_dir = File.join(tmpdir, "older")
    newer_dir = File.join(tmpdir, "newer")
    FileUtils.mkdir_p([older_dir, newer_dir])

    t0 = Time.utc(2026, 1, 1, 12, 0, 0)
    allow(Time).to receive(:now).and_return(t0, t0 + 5, t0 + 10)

    older = manager.open(older_dir)
    newer = manager.open(newer_dir)
    expect(manager.list.map { |p| p[:id] }).to eq([newer[:id], older[:id]])

    manager.touch(older[:id])
    expect(manager.list.map { |p| p[:id] }).to eq([older[:id], newer[:id]])
  end

  it "finds projects by normalized path" do
    project = manager.open(project_dir)
    found = manager.find_by_path(project_dir + "/")

    expect(found[:id]).to eq(project[:id])
  end

  it "collapses symlink and relative path variants to one project" do
    link = File.join(tmpdir, "link-app")
    FileUtils.ln_s(project_dir, link)

    first = manager.open(File.join(tmpdir, "x", "..", "app"))
    second = manager.open(link)

    expect(second[:id]).to eq(first[:id])
    expect(first[:path]).to eq(File.realpath(project_dir))
    expect(manager.list.size).to eq(1)
  end

  it "renames and removes project records without deleting the directory" do
    project = manager.open(project_dir)
    renamed = manager.rename(project[:id], "Renamed")
    expect(renamed[:name]).to eq("Renamed")

    expect(manager.remove(project[:id])).to be true
    expect(manager.list).to be_empty
    expect(Dir.exist?(project_dir)).to be true
  end

  it "rejects missing directories" do
    expect {
      manager.open(File.join(tmpdir, "missing"))
    }.to raise_error(ArgumentError, /Directory not found/)
  end

  it "backs up a corrupt projects file and recovers to an empty list" do
    File.write(file_path, "{not-json")
    expect(manager.list).to eq([])
    backups = Dir.glob("#{file_path}.corrupt.*")
    expect(backups).not_to be_empty
    expect(JSON.parse(File.read(file_path))).to eq("projects" => [])
  end
end
