# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::AgentProfile, "with extension-contributed agents" do
  let(:builtin)   { Dir.mktmpdir }
  let(:installed) { Dir.mktmpdir }
  let(:local)     { Dir.mktmpdir }

  after do
    [builtin, installed, local].each { |d| FileUtils.remove_entry(d) if Dir.exist?(d) }
    Clacky::ExtensionLoader.instance_variable_set(:@last_result, nil)
  end

  def make_ext(root, ext_id, manifest, files = {})
    dir = File.join(root, ext_id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "ext.yml"), manifest)
    files.each do |rel, content|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    dir
  end

  def reload_layers
    Clacky::ExtensionLoader.load_all(
      layers: { builtin: builtin, installed: installed, local: local }
    )
  end

  it "loads description and system_prompt from an ext agent unit" do
    manifest = <<~YAML
      id: support-pack
      origin: self
      contributes:
        agents:
          - id: support
            prompt: prompts/support.md
            description: Customer support agent
            panels: [inbox]
            skills: [triage]
    YAML
    make_ext(local, "support-pack", manifest, "prompts/support.md" => "You handle inbound tickets.")

    reload_layers

    profile = described_class.load("support")
    expect(profile.name).to eq("support")
    expect(profile.description).to eq("Customer support agent")
    expect(profile.system_prompt).to eq("You handle inbound tickets.")
  end

  it "raises when neither physical dir nor ext unit exists" do
    reload_layers
    expect { described_class.load("ghost") }.to raise_error(ArgumentError, /not found/)
  end

  it "reads disabled_skills from the ext agent spec and blocks those skills" do
    manifest = <<~YAML
      id: lean-pack
      origin: self
      contributes:
        agents:
          - id: lean
            prompt: prompts/lean.md
            description: Minimal agent
            disabled_skills: [cron-task-creator, media-gen]
    YAML
    make_ext(local, "lean-pack", manifest, "prompts/lean.md" => "Lean agent.")

    reload_layers

    profile = described_class.load("lean")
    expect(profile.disabled_skills).to eq(%w[cron-task-creator media-gen])

    disabled = double("skill", identifier: "cron-task-creator")
    expect(profile.skill_allowed?(disabled)).to be(false)

    allowed = double("skill", identifier: "commit")
    allow(allowed).to receive(:allowed_for_agent?).with("lean").and_return(true)
    expect(profile.skill_allowed?(allowed)).to be(true)
  end

  it "lets a physical user dir override an ext unit with the same id" do
    manifest = <<~YAML
      id: shadow-pack
      origin: self
      contributes:
        agents:
          - id: shadowed
            prompt: prompts/from_ext.md
            description: from ext
    YAML
    make_ext(local, "shadow-pack", manifest, "prompts/from_ext.md" => "ext prompt")

    reload_layers

    user_dir = File.join(Clacky::AgentProfile::USER_AGENTS_DIR, "shadowed")
    FileUtils.mkdir_p(user_dir)
    begin
      File.write(File.join(user_dir, "profile.yml"), { "name" => "shadowed", "description" => "user wins" }.to_yaml)
      File.write(File.join(user_dir, "system_prompt.md"), "user prompt")

      profile = described_class.load("shadowed")
      expect(profile.description).to eq("user wins")
      expect(profile.system_prompt).to eq("user prompt")
    ensure
      FileUtils.remove_entry(user_dir) if Dir.exist?(user_dir)
    end
  end
end
