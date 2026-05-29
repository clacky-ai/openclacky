# frozen_string_literal: true

require "tmpdir"
require "json"
require "fileutils"

RSpec.describe Clacky::Mcp::SkillProvider do
  let(:home) { Dir.mktmpdir }
  let(:work) { Dir.mktmpdir }

  before do
    FileUtils.mkdir_p(File.join(home, ".clacky"))
    stub_const("ENV", ENV.to_hash.merge("HOME" => home))
    allow(Dir).to receive(:home).and_return(home)
  end

  after do
    FileUtils.rm_rf(home)
    FileUtils.rm_rf(work)
  end

  def write_global(servers)
    File.write(File.join(home, ".clacky", "mcp.json"), JSON.dump("mcpServers" => servers))
  end

  it "returns an empty array when mcp.json does not exist" do
    expect(described_class.new(working_dir: work).virtual_skills).to eq([])
  end

  it "produces a VirtualSkill per stdio server" do
    write_global(
      "github" => { "command" => "npx", "args" => %w[gh-mcp], "description" => "GitHub stuff" }
    )
    skills = described_class.new(working_dir: work).virtual_skills
    expect(skills.size).to eq(1)
    sk = skills.first
    expect(sk).to be_a(Clacky::Mcp::VirtualSkill)
    expect(sk.identifier).to eq("mcp:github")
    expect(sk.description).to eq("GitHub stuff")
    expect(sk.fork_agent?).to eq(true)
  end

  it "supports http servers" do
    write_global(
      "linear" => { "type" => "http", "url" => "https://example.com/mcp" }
    )
    skills = described_class.new(working_dir: work).virtual_skills
    expect(skills.map(&:identifier)).to eq(["mcp:linear"])
  end

  it "skips disabled or invalid servers" do
    write_global(
      "off" => { "command" => "x", "disabled" => true },
      "no_command" => { "args" => ["x"] },
      "ok" => { "command" => "x" }
    )
    skills = described_class.new(working_dir: work).virtual_skills
    expect(skills.map(&:identifier)).to eq(["mcp:ok"])
  end

  it "spawns no subprocess and never reads tool schemas" do
    # If the provider tried to spawn a server we'd see a child process — assert
    # by stubbing Open3 to fail loudly if anyone calls it.
    expect(Open3).not_to receive(:popen3)
    write_global("github" => { "command" => "echo", "args" => ["hi"] })
    described_class.new(working_dir: work).virtual_skills
  end
end
