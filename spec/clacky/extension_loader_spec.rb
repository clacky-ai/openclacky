# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ExtensionLoader do
  let(:builtin)   { Dir.mktmpdir }
  let(:installed) { Dir.mktmpdir }
  let(:local)     { Dir.mktmpdir }

  let(:layers) { { builtin: builtin, installed: installed, local: local } }

  after do
    [builtin, installed, local].each { |d| FileUtils.remove_entry(d) if Dir.exist?(d) }
  end

  def make_container(root, id, manifest:, files: {})
    dir = File.join(root, id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "ext.yml"), manifest)
    files.each do |rel, content|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    dir
  end

  describe ".load_all" do
    it "resolves a panel unit alongside a top-level api backend" do
      manifest = <<~YAML
        id: hello
        origin: self
        contributes:
          api: api/handler.rb
          panels:
            - id: hello
              view: panels/hello/view.js
      YAML
      make_container(local, "hello", manifest: manifest, files: {
        "panels/hello/view.js" => "// view",
        "api/handler.rb"       => "# handler",
      })

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      expect(result.panels.size).to eq(1)
      expect(result.api.size).to eq(1)

      panel = result.panels.first
      expect(panel.ext_id).to eq("hello")
      expect(panel.spec["attach"]).to eq([])

      api = result.api.first
      expect(api.ext_id).to eq("hello")
      expect(api.spec["handler_abs"]).to end_with("api/handler.rb")
    end

    it "lets a higher layer override the same id and records the override" do
      manifest = <<~YAML
        id: dup
        origin: self
        contributes:
          panels:
            - id: p
              view: view.js
      YAML

      make_container(builtin, "dup", manifest: manifest, files: { "view.js" => "// builtin" })
      make_container(local, "dup", manifest: manifest, files: { "view.js" => "// local" })

      result = described_class.load_all(layers: layers)

      expect(result.panels.size).to eq(1)
      expect(result.panels.first.layer).to eq(:local)
      expect(result.overridden).to eq([["dup", :builtin, :local]])
    end

    it "records a structured error when a panel view file is missing" do
      make_container(local, "broken", manifest: <<~YAML)
        id: broken
        origin: self
        contributes:
          panels:
            - id: p
              view: panels/missing.js
      YAML

      result = described_class.load_all(layers: layers)

      expect(result.panels).to be_empty
      expect(result.errors.size).to eq(1)
      expect(result.errors.first.ext_id).to eq("broken")
      expect(result.errors.first.message).to match(/view file not found/)
    end

    it "rejects an invalid origin" do
      make_container(local, "bad-origin", manifest: <<~YAML, files: { "view.js" => "" })
        id: bad-origin
        origin: pirate
        contributes:
          panels:
            - id: p
              view: view.js
      YAML

      result = described_class.load_all(layers: layers)

      expect(result.units).to be_empty
      expect(result.errors.first.message).to match(/invalid origin/)
    end

    it "accepts a panel with attach: [<agent>]" do
      make_container(local, "attach-agent", manifest: <<~YAML, files: { "view.js" => "" })
        id: attach-agent
        origin: self
        contributes:
          panels:
            - id: p
              view: view.js
              attach: [designer]
      YAML

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      expect(result.panels.first.spec["attach"]).to eq(["designer"])
    end

    it 'accepts a panel with attach: ["*"]' do
      make_container(local, "attach-star", manifest: <<~YAML, files: { "view.js" => "" })
        id: attach-star
        origin: self
        contributes:
          panels:
            - id: p
              view: view.js
              attach: ["*"]
      YAML

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      expect(result.panels.first.spec["attach"]).to eq(["*"])
    end

    it "isolates a malformed ext.yml without aborting other containers" do
      make_container(local, "good", manifest: <<~YAML, files: { "view.js" => "" })
        id: good
        origin: self
        contributes:
          panels:
            - id: p
              view: view.js
      YAML
      make_container(local, "junk", manifest: "just a string")

      result = described_class.load_all(layers: layers)

      expect(result.panels.map(&:ext_id)).to eq(["good"])
      expect(result.errors.map(&:ext_id)).to include("junk")
    end

    it "returns empty when no containers exist" do
      result = described_class.load_all(layers: layers)
      expect(result.units).to be_empty
      expect(result.errors).to be_empty
    end

    it "resolves a plain skill unit" do
      manifest = <<~YAML
        id: triage-pack
        origin: self
        contributes:
          skills:
            - id: triage
      YAML
      make_container(local, "triage-pack", manifest: manifest, files: {
        "skills/triage/SKILL.md" => "---\nname: triage\ndescription: Triage incidents\n---\nbody",
      })

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      expect(result.skills.size).to eq(1)
      unit = result.skills.first
      expect(unit.kind).to eq(:skill)
      expect(unit.id).to eq("triage")
      expect(unit.spec["protected"]).to eq(false)
      expect(unit.spec["encrypted"]).to eq(false)
      expect(unit.spec["skill_dir_abs"]).to end_with("skills/triage")
    end

    it "marks a marketplace skill protected by default" do
      manifest = <<~YAML
        id: paid-pack
        origin: marketplace
        contributes:
          skills:
            - id: closed
      YAML
      make_container(installed, "paid-pack", manifest: manifest, files: {
        "skills/closed/SKILL.md.enc" => "encrypted-bytes",
      })

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      unit = result.skills.first
      expect(unit.spec["protected"]).to eq(true)
      expect(unit.spec["encrypted"]).to eq(true)
    end

    it "honors an explicit protected override" do
      manifest = <<~YAML
        id: mixed-pack
        origin: marketplace
        contributes:
          skills:
            - id: free-tease
              protected: false
      YAML
      make_container(installed, "mixed-pack", manifest: manifest, files: {
        "skills/free-tease/SKILL.md" => "---\nname: free-tease\ndescription: tease\n---\n",
      })

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      expect(result.skills.first.spec["protected"]).to eq(false)
    end

    it "supports a custom skill dir override" do
      manifest = <<~YAML
        id: cu-pack
        origin: self
        contributes:
          skills:
            - id: alt
              dir: nested/alt-skill
      YAML
      make_container(local, "cu-pack", manifest: manifest, files: {
        "nested/alt-skill/SKILL.md" => "---\nname: alt\ndescription: alt\n---\n",
      })

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      expect(result.skills.first.spec["skill_dir_abs"]).to end_with("nested/alt-skill")
    end

    it "errors when skill dir is missing" do
      manifest = <<~YAML
        id: bad-skill
        origin: self
        contributes:
          skills:
            - id: ghost
      YAML
      make_container(local, "bad-skill", manifest: manifest)

      result = described_class.load_all(layers: layers)

      expect(result.skills).to be_empty
      expect(result.errors.first.message).to match(/skill dir not found/)
    end

    it "errors when SKILL.md and SKILL.md.enc are both missing" do
      manifest = <<~YAML
        id: empty-skill
        origin: self
        contributes:
          skills:
            - id: ghost
      YAML
      make_container(local, "empty-skill", manifest: manifest, files: {
        "skills/ghost/.keep" => "",
      })

      result = described_class.load_all(layers: layers)

      expect(result.skills).to be_empty
      expect(result.errors.first.message).to match(/SKILL\.md or SKILL\.md\.enc/)
    end

    it "resolves an agent unit with prompt, panels and skills refs" do
      manifest = <<~YAML
        id: support-pack
        origin: self
        contributes:
          agents:
            - id: support
              prompt: prompts/support.md
              description: Customer support agent
              panels: [inbox, replies]
              skills: [triage]
      YAML
      make_container(local, "support-pack", manifest: manifest, files: {
        "prompts/support.md" => "You are a support agent.",
      })

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      expect(result.agents.size).to eq(1)
      unit = result.agents.first
      expect(unit.kind).to eq(:agent)
      expect(unit.id).to eq("support")
      expect(unit.spec["description"]).to eq("Customer support agent")
      expect(unit.spec["panels"]).to eq(["inbox", "replies"])
      expect(unit.spec["skills"]).to eq(["triage"])
      expect(unit.spec["prompt_abs"]).to end_with("prompts/support.md")
    end

    it "errors when an agent prompt file is missing" do
      manifest = <<~YAML
        id: ghost-pack
        origin: self
        contributes:
          agents:
            - id: ghost
              prompt: prompts/missing.md
      YAML
      make_container(local, "ghost-pack", manifest: manifest)

      result = described_class.load_all(layers: layers)

      expect(result.agents).to be_empty
      expect(result.errors.first.message).to match(/prompt file not found/)
    end

    it "errors when an agent unit lacks id or prompt" do
      manifest = <<~YAML
        id: half-pack
        origin: self
        contributes:
          agents:
            - id: nameless
      YAML
      make_container(local, "half-pack", manifest: manifest)

      result = described_class.load_all(layers: layers)

      expect(result.agents).to be_empty
      expect(result.errors.first.message).to match(/agent needs both `id` and `prompt`/)
    end

    it "resolves a channel unit pointing at an adapter file" do
      manifest = <<~YAML
        id: slack-pack
        origin: self
        contributes:
          channels:
            - id: slack
              adapter: channels/slack.rb
      YAML
      make_container(local, "slack-pack", manifest: manifest, files: {
        "channels/slack.rb" => "# adapter file",
      })

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      expect(result.channels.size).to eq(1)
      unit = result.channels.first
      expect(unit.kind).to eq(:channel)
      expect(unit.id).to eq("slack")
      expect(unit.spec["adapter_abs"]).to end_with("channels/slack.rb")
    end

    it "errors when a channel adapter file is missing" do
      manifest = <<~YAML
        id: ghost-channel
        origin: self
        contributes:
          channels:
            - id: ghost
              adapter: channels/missing.rb
      YAML
      make_container(local, "ghost-channel", manifest: manifest)

      result = described_class.load_all(layers: layers)

      expect(result.channels).to be_empty
      expect(result.errors.first.message).to match(/adapter file not found/)
    end

    it "resolves a patch unit pointing at a target and file" do
      manifest = <<~YAML
        id: patch-pack
        origin: self
        contributes:
          patches:
            - target: "Clacky::Tools::WebSearch#execute"
              file: patches/timeout.rb
      YAML
      make_container(local, "patch-pack", manifest: manifest, files: {
        "patches/timeout.rb" => "# patch content",
      })

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      expect(result.patches.size).to eq(1)
      unit = result.patches.first
      expect(unit.kind).to eq(:patch)
      expect(unit.spec["target"]).to eq("Clacky::Tools::WebSearch#execute")
      expect(unit.spec["file_abs"]).to end_with("patches/timeout.rb")
      expect(unit.spec["on_mismatch"]).to eq("disable")
    end

    it "errors when a patch file is missing" do
      manifest = <<~YAML
        id: ghost-patch
        origin: self
        contributes:
          patches:
            - target: "Some::Class#method"
              file: patches/missing.rb
      YAML
      make_container(local, "ghost-patch", manifest: manifest)

      result = described_class.load_all(layers: layers)

      expect(result.patches).to be_empty
      expect(result.errors.first.message).to match(/patch file not found/)
    end

    it "resolves a hook unit pointing at an event and file" do
      manifest = <<~YAML
        id: hook-pack
        origin: self
        contributes:
          hooks:
            - event: before_tool_use
              file: hooks/audit.rb
      YAML
      make_container(local, "hook-pack", manifest: manifest, files: {
        "hooks/audit.rb" => "# hook content",
      })

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      expect(result.hooks.size).to eq(1)
      unit = result.hooks.first
      expect(unit.kind).to eq(:hook)
      expect(unit.spec["event"]).to eq("before_tool_use")
      expect(unit.spec["file_abs"]).to end_with("hooks/audit.rb")
    end

    it "errors when a hook file is missing" do
      manifest = <<~YAML
        id: ghost-hook
        origin: self
        contributes:
          hooks:
            - event: on_complete
              file: hooks/missing.rb
      YAML
      make_container(local, "ghost-hook", manifest: manifest)

      result = described_class.load_all(layers: layers)

      expect(result.hooks).to be_empty
      expect(result.errors.first.message).to match(/hook file not found/)
    end

    it "resolves a tool unit pointing at a tool file" do
      manifest = <<~YAML
        id: tool-pack
        origin: self
        contributes:
          tools:
            - id: weather
              file: tools/weather.rb
      YAML
      make_container(local, "tool-pack", manifest: manifest, files: {
        "tools/weather.rb" => "# tool content",
      })

      result = described_class.load_all(layers: layers)

      expect(result.errors).to be_empty
      expect(result.tools.size).to eq(1)
      unit = result.tools.first
      expect(unit.kind).to eq(:tool)
      expect(unit.id).to eq("weather")
      expect(unit.spec["file_abs"]).to end_with("tools/weather.rb")
      expect(result.units).to include(unit)
    end

    it "errors when a tool file is missing" do
      manifest = <<~YAML
        id: ghost-tool
        origin: self
        contributes:
          tools:
            - id: weather
              file: tools/missing.rb
      YAML
      make_container(local, "ghost-tool", manifest: manifest)

      result = described_class.load_all(layers: layers)

      expect(result.tools).to be_empty
      expect(result.errors.first.message).to match(/tool file not found/)
    end
  end

  describe "manifest mtime cache" do
    let(:manifest_v1) do
      <<~YAML
        id: cached
        origin: self
        contributes:
          api:
            - id: cached
              handler: handler.rb
      YAML
    end

    let(:manifest_v2) do
      <<~YAML
        id: cached
        name: renamed
        origin: self
        contributes:
          api:
            - id: cached
              handler: handler.rb
      YAML
    end

    it "returns the exact same Result object on repeated calls with unchanged manifests" do
      make_container(local, "cached", manifest: manifest_v1, files: { "handler.rb" => "# handler" })

      first = described_class.load_all(layers: layers)
      second = described_class.load_all(layers: layers)

      expect(second).to be(first)
    end

    it "rescans when a manifest mtime changes" do
      dir = make_container(local, "cached", manifest: manifest_v1, files: { "handler.rb" => "# handler" })

      first = described_class.load_all(layers: layers)
      expect(first.containers["cached"][:dir]).to eq(dir)

      manifest = File.join(dir, "ext.yml")
      File.write(manifest, manifest_v2)
      File.utime(Time.now + 5, Time.now + 5, manifest)

      second = described_class.load_all(layers: layers)

      expect(second).not_to be(first)
      expect(second.containers["cached"]).not_to be_nil
    end

    it "rescans when a new container is added" do
      make_container(local, "cached", manifest: manifest_v1, files: { "handler.rb" => "# handler" })
      first = described_class.load_all(layers: layers)
      expect(first.containers.keys).to eq(["cached"])

      make_container(local, "second", manifest: manifest_v1.sub("id: cached", "id: second"),
                     files: { "handler.rb" => "# handler" })
      second = described_class.load_all(layers: layers)
      expect(second.containers.keys).to contain_exactly("cached", "second")
    end

    it "rescans on force: true even when nothing changed" do
      make_container(local, "cached", manifest: manifest_v1, files: { "handler.rb" => "# handler" })
      first = described_class.load_all(layers: layers)
      forced = described_class.load_all(layers: layers, force: true)
      expect(forced).not_to be(first)
    end
  end
end
