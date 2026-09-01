# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::AgentProfile, ".all" do
  let(:user_dir)  { Dir.mktmpdir }
  let(:ext_local) { Dir.mktmpdir }

  before do
    stub_const("Clacky::AgentProfile::USER_AGENTS_DIR", user_dir)
    Clacky::ExtensionLoader.load_all(layers: { local: ext_local })
  end

  after do
    [user_dir, ext_local].each { |d| FileUtils.remove_entry(d) if Dir.exist?(d) }
    Clacky::ExtensionLoader.instance_variable_set(:@last_result, nil)
  end

  def make_user(id, title:, description: "")
    path = File.join(user_dir, id)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "profile.yml"), { "title" => title, "description" => description }.to_yaml)
    File.write(File.join(path, "system_prompt.md"), "user prompt")
  end

  def make_ext_agent(ext_id, agent_id, title:, description: "", title_zh: "", hidden: false)
    dir = File.join(ext_local, ext_id)
    FileUtils.mkdir_p(File.join(dir, "prompts"))
    agent = {
      "id" => agent_id,
      "title" => title,
      "description" => description,
      "prompt" => "prompts/p.md",
    }
    agent["title_zh"] = title_zh unless title_zh.empty?
    agent["hidden"] = true if hidden
    manifest = {
      "id" => ext_id,
      "origin" => "self",
      "contributes" => { "agents" => [agent] },
    }
    File.write(File.join(dir, "ext.yml"), manifest.to_yaml)
    File.write(File.join(dir, "prompts", "p.md"), "ext prompt")
    Clacky::ExtensionLoader.load_all(layers: { local: ext_local })
  end

  it "lists extension-contributed agents" do
    make_ext_agent("coding-pack", "coding", title: "Coding")
    make_ext_agent("general-pack", "general", title: "General")

    ids = described_class.all.map { |a| a[:id] }
    expect(ids).to contain_exactly("coding", "general")
    expect(described_class.all.first[:source]).to eq("extension")
  end

  it "merges user override with extension agents" do
    make_ext_agent("designer-pack", "designer", title: "Designer", description: "design things")

    all = described_class.all
    designer = all.find { |a| a[:id] == "designer" }

    expect(designer).to include(id: "designer", title: "Designer", source: "extension")
    expect(designer[:description]).to eq("design things")
  end

  it "user override beats extension for the same id" do
    make_user("coding", title: "Coding (user)", description: "my override")
    make_ext_agent("override-pack", "coding", title: "Coding (ext)")

    coding = described_class.all.find { |a| a[:id] == "coding" }
    expect(coding[:source]).to eq("user")
    expect(coding[:title]).to eq("Coding (user)")
  end

  it "orders third-party extension agents by most-recently-used when recency is given" do
    make_ext_agent("alpha-pack", "alpha", title: "Alpha")
    make_ext_agent("beta-pack", "beta", title: "Beta")

    ids = described_class.all(recency: { "beta" => 200, "alpha" => 100 }).map { |a| a[:id] }
    expect(ids.index("beta")).to be < ids.index("alpha")
  end

  it "falls back to declared order for extension agents with no recency data" do
    make_ext_agent("alpha-pack", "alpha", title: "Alpha")
    make_ext_agent("beta-pack", "beta", title: "Beta")

    ids = described_class.all.map { |a| a[:id] }
    expect(ids).to contain_exactly("alpha", "beta")
  end

  it "keeps hidden extension agents (flagged) so existing sessions can resolve their names" do
    make_ext_agent("painter-pack", "painter", title: "Painter", title_zh: "画家", hidden: true)
    make_ext_agent("general-pack", "general", title: "General")

    all = described_class.all
    painter = all.find { |a| a[:id] == "painter" }
    general = all.find { |a| a[:id] == "general" }

    expect(all.map { |a| a[:id] }).to include("painter", "general")
    expect(painter[:hidden]).to be true
    expect(painter[:title_zh]).to eq("画家")
    expect(general[:hidden]).to be false
  end
end
