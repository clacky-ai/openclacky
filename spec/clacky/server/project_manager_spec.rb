# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Server::ProjectManager do
  let(:projects_file) { File.join(Dir.tmpdir, "clacky-project-manager-spec-#{SecureRandom.hex(4)}.json") }
  let(:manager) { described_class.new(projects_file: projects_file) }

  after { File.delete(projects_file) if File.exist?(projects_file) }

  def create_project(name)
    manager.create(name: name)
  end

  describe "#update with pinned" do
    it "sets pinned_at when pinned" do
      project = create_project("alpha")

      updated = manager.update(project[:id], pinned: true)

      expect(updated[:pinned_at]).not_to be_nil
      expect(manager.find(project[:id])[:pinned_at]).not_to be_nil
    end

    it "clears pinned_at when unpinned" do
      project = create_project("alpha")
      manager.update(project[:id], pinned: true)

      updated = manager.update(project[:id], pinned: false)

      expect(updated[:pinned_at]).to be_nil
      expect(manager.find(project[:id])[:pinned_at]).to be_nil
    end

    it "refreshes pinned_at when re-pinning" do
      project = create_project("alpha")
      first_at = manager.update(project[:id], pinned: true)[:pinned_at]
      manager.update(project[:id], pinned: false)

      second_at = manager.update(project[:id], pinned: true)[:pinned_at]

      expect(second_at).to be >= first_at
    end

    it "leaves pinned_at untouched when the key is not provided" do
      project = create_project("alpha")
      manager.update(project[:id], pinned: true)

      updated = manager.update(project[:id], name: "renamed")

      expect(updated[:name]).to eq("renamed")
      expect(updated[:pinned_at]).not_to be_nil
    end

    it "returns nil for an unknown id" do
      expect(manager.update("nope", pinned: true)).to be_nil
    end
  end

  describe "persistence" do
    it "round-trips pinned_at through disk" do
      project = create_project("alpha")
      manager.update(project[:id], pinned: true)

      reloaded = described_class.new(projects_file: projects_file)

      expect(reloaded.find(project[:id])[:pinned_at]).not_to be_nil
    end

    it "tolerates legacy entries without pinned_at" do
      legacy = [{ id: "deadbeef", name: "legacy", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z" }]
      File.write(projects_file, JSON.pretty_generate(legacy))

      expect(manager.find("deadbeef")[:pinned_at]).to be_nil
    end
  end
end
