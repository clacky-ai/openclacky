# frozen_string_literal: true

require "spec_helper"
require "clacky/extension/scaffold"
require "clacky/extension/loader"
require "clacky/extension/verifier"
require "tmpdir"
require "yaml"

RSpec.describe Clacky::ExtensionScaffold, "full container" do
  let(:tmp) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  it "scaffolds a manifest contributing all 8 unit types" do
    Clacky::ExtensionScaffold.new_container("demo", dir: tmp, full: true)

    manifest = YAML.safe_load(File.read(File.join(tmp, "demo", "ext.yml")))
    expect(manifest["contributes"].keys).to match_array(
      %w[panels api skills agents channels patches hooks tools]
    )
  end

  it "produces a container that loads cleanly with no loader errors" do
    Clacky::ExtensionScaffold.new_container("demo", dir: tmp, full: true)

    result = Clacky::ExtensionLoader.load_all(layers: { local: tmp })

    expect(result.errors).to be_empty
    kinds = result.units.map(&:kind).uniq
    expect(kinds).to include(:panel, :api, :skill, :agent, :channel, :patch, :hook, :tool)
  end

  it "scaffolds a runnable contributed tool file" do
    Clacky::ExtensionScaffold.new_container("demo", dir: tmp, full: true)

    tool_file = File.join(tmp, "demo", "tools", "hello.rb")
    expect(File).to exist(tool_file)

    result = Clacky::ExtensionLoader.load_all(layers: { local: tmp })
    tool = result.tools.find { |u| u.id == "hello" }
    expect(tool).not_to be_nil
    expect(tool.spec["file_abs"]).to eq(tool_file)
  end

  it "verifies clean (no errors, no warnings)" do
    Clacky::ExtensionScaffold.new_container("demo", dir: tmp, full: true)

    result = Clacky::ExtensionLoader.load_all(layers: { local: tmp })
    issues = Clacky::ExtensionVerifier.verify(result)

    expect(issues).to be_empty
  end

  it "default mode (no --full) still scaffolds the minimal hello panel" do
    Clacky::ExtensionScaffold.new_container("hello", dir: tmp)

    expect(File).to exist(File.join(tmp, "hello", "panels", "hello", "view.js"))
    expect(File).not_to exist(File.join(tmp, "hello", "channels"))
  end
end
