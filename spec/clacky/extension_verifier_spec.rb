# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ExtensionVerifier do
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
  end

  def reload_layers
    Clacky::ExtensionLoader.load_all(layers: { builtin: builtin, installed: installed, local: local })
  end

  it "flags unknown top-level keys in ext.yml" do
    manifest = <<~YAML
      id: bad-top-key
      origin: self
      randomKey: oops
      contributes: {}
    YAML
    make_ext(local, "bad-top-key", manifest)
    result = reload_layers

    issues = described_class.verify(result)
    codes = issues.map(&:code)
    expect(codes).to include("schema.unknown_key")
    expect(issues.find { |i| i.code == "schema.unknown_key" }.level).to eq(:warning)
  end

  it "flags unknown contributes type" do
    manifest = <<~YAML
      id: bad-contrib
      origin: self
      contributes:
        widgets: []
    YAML
    make_ext(local, "bad-contrib", manifest)
    result = reload_layers

    issues = described_class.verify(result)
    expect(issues.map(&:code)).to include("schema.unknown_contributes")
  end

  it "flags unknown unit-level fields" do
    manifest = <<~YAML
      id: typo-pack
      origin: self
      contributes:
        panels:
          - id: hello
            title: Hello
            attach: ["*"]
            view: view.js
            mistypedField: yes
    YAML
    make_ext(local, "typo-pack", manifest, "view.js" => "//")
    result = reload_layers

    issues = described_class.verify(result)
    field_issue = issues.find { |i| i.code == "schema.unknown_field" }
    expect(field_issue).not_to be_nil
    expect(field_issue.message).to include("mistypedField")
  end

  it "accepts the hidden field on agents without warning" do
    manifest = <<~YAML
      id: hidden-agent-pack
      origin: self
      contributes:
        agents:
          - id: secret
            title: Secret
            description: x
            prompt: prompt.md
            hidden: true
    YAML
    make_ext(local, "hidden-agent-pack", manifest, "prompt.md" => "hi")
    result = reload_layers

    issues = described_class.verify(result)
    unknown = issues.select { |i| i.code == "schema.unknown_field" && i.unit == "secret" }
    expect(unknown).to be_empty
  end

  it "flags an agent referencing a non-existent panel" do
    manifest = <<~YAML
      id: ghost-ref
      origin: self
      contributes:
        agents:
          - id: ghosty
            title: Ghosty
            description: x
            prompt: prompt.md
            panels: [does-not-exist]
    YAML
    make_ext(local, "ghost-ref", manifest, "prompt.md" => "hi")
    result = reload_layers

    issues = described_class.verify(result)
    miss = issues.find { |i| i.code == "ref.missing_panel" }
    expect(miss).not_to be_nil
    expect(miss.level).to eq(:error)
  end

  it "passes when an agent references a panel actually contributed by the same container" do
    manifest = <<~YAML
      id: linked
      origin: self
      contributes:
        panels:
          - id: dash
            title: Dash
            view: view.js
        agents:
          - id: designer
            title: D
            description: d
            prompt: prompt.md
            panels: [dash]
    YAML
    make_ext(local, "linked", manifest, "view.js" => "//", "prompt.md" => "x")
    result = reload_layers

    issues = described_class.verify(result)
    expect(issues.map(&:code)).not_to include("ref.missing_panel")
  end

  it "surfaces loader errors as issues" do
    manifest = <<~YAML
      id: missing-view
      origin: self
      contributes:
        panels:
          - id: hello
            title: Hello
            attach: ["*"]
            view: nope.js
    YAML
    make_ext(local, "missing-view", manifest)
    result = reload_layers

    issues = described_class.verify(result)
    expect(issues.map(&:code)).to include("loader.error")
  end

  it "reports container override across layers as a warning" do
    manifest_a = "id: dup\norigin: self\ncontributes: {}\n"
    make_ext(installed, "dup", manifest_a)
    make_ext(local,     "dup", manifest_a)
    result = reload_layers

    issues = described_class.verify(result)
    over = issues.find { |i| i.code == "override" }
    expect(over).not_to be_nil
    expect(over.level).to eq(:warning)
  end

  it "flags a malformed panel `attach` value" do
    manifest = <<~YAML
      id: bad-attach
      origin: self
      contributes:
        panels:
          - id: hello
            view: view.js
            attach: nope
    YAML
    make_ext(local, "bad-attach", manifest, "view.js" => "//")
    result = reload_layers

    issues = described_class.verify(result)
    bad = issues.find { |i| i.code == "schema.bad_attach" }
    expect(bad).not_to be_nil
    expect(bad.level).to eq(:error)
  end

  it "warns when panel.attach references a non-existent agent" do
    manifest = <<~YAML
      id: dangling-attach
      origin: self
      contributes:
        panels:
          - id: hello
            view: view.js
            attach: [nobody]
    YAML
    make_ext(local, "dangling-attach", manifest, "view.js" => "//")
    result = reload_layers

    issues = described_class.verify(result)
    miss = issues.find { |i| i.code == "ref.missing_attach_agent" }
    expect(miss).not_to be_nil
    expect(miss.level).to eq(:warning)
  end

  it "reports no issues for the gem's own bundled default extensions" do
    result = Clacky::ExtensionLoader.load_all(
      layers: { builtin: Clacky::ExtensionLoader::BUILTIN_DIR }, force: true
    )

    issues = described_class.verify(result)
    expect(issues).to be_empty, -> { issues.map { |i| "#{i.code} #{i.ext}: #{i.message}" }.join("\n") }
  end
end
