# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"

# End-to-end smoke: a single ext.yml container contributing every supported
# type at once, walked through ExtensionLoader, Verifier, ExtensionAdapterLoader,
# PatchLoader, and ExtensionHookLoader/Registry. This is the activated form of
# the "kitchen-sink" reference container in the architecture doc.

module ExtKitchenFixture
  class WidgetTarget
    def render
      "plain"
    end
  end
end

RSpec.describe "ExtensionLoader end-to-end with a kitchen-sink container" do
  let(:builtin)   { Dir.mktmpdir }
  let(:installed) { Dir.mktmpdir }
  let(:local)     { Dir.mktmpdir }
  let(:patches_dir) { Dir.mktmpdir }

  let(:ext_id) { "kitchen-sink" }
  let(:ext_dir) { File.join(local, ext_id) }

  before do
    FileUtils.mkdir_p(File.join(ext_dir, "panels"))
    FileUtils.mkdir_p(File.join(ext_dir, "api"))
    FileUtils.mkdir_p(File.join(ext_dir, "skills/sample-skill"))
    FileUtils.mkdir_p(File.join(ext_dir, "channels"))
    FileUtils.mkdir_p(File.join(ext_dir, "patches"))
    FileUtils.mkdir_p(File.join(ext_dir, "hooks"))
    FileUtils.mkdir_p(File.join(ext_dir, "runtime"))

    File.write(File.join(ext_dir, "ext.yml"), <<~YAML)
      id: #{ext_id}
      title: Kitchen Sink Demo
      description: Reference container exercising every contributes type.
      version: "0.0.1"
      origin: self
      contributes:
        api: api/handler.rb
        panels:
          - id: dashboard
            title: Dashboard
            view: panels/dashboard.js
        skills:
          - id: sample-skill
        agents:
          - id: designer
            title: Designer
            description: Builds nice things.
            prompt: agents/designer.md
            panels: [dashboard]
            skills: [sample-skill]
        channels:
          - id: noop
            platform: noop_kitchen
            adapter: channels/noop.rb
        patches:
          - target: "ExtKitchenFixture::WidgetTarget#render"
            file: patches/widget.rb
        hooks:
          - event: before_tool_use
            file: hooks/audit.rb
        providers:
          - id: kitchen-provider
            name: Kitchen Provider
            runtime_id: kitchen-runtime
            auth_mode: runtime
            credential_fields: []
            dynamic_models: session
            display_model: Kitchen default
        agent_runtimes:
          - id: kitchen-runtime
            adapter: runtime/noop.rb
            class: ExtKitchenFixture::Runtime
    YAML

    File.write(File.join(ext_dir, "panels/dashboard.js"), "// dashboard panel\n")
    File.write(File.join(ext_dir, "api/handler.rb"), "# api handler\n")
    FileUtils.mkdir_p(File.join(ext_dir, "agents"))
    File.write(File.join(ext_dir, "agents/designer.md"), "You are the designer.\n")
    File.write(File.join(ext_dir, "skills/sample-skill/SKILL.md"), <<~MD)
      ---
      name: sample-skill
      description: A throwaway skill for kitchen-sink verification.
      ---
      Hello.
    MD

    File.write(File.join(ext_dir, "channels/noop.rb"), <<~RUBY)
      module Clacky
        module Channel
          module Adapters
            class NoopKitchenAdapter < Base
              def self.platform_id; :noop_kitchen; end
              def self.platform_config(_data); {}; end
              def initialize(config); @config = config; end
              def start(&_); end
              def stop; end
              def send_text(_chat, _text, reply_to: nil); { message_id: "1" }; end
              Adapters.register(platform_id, self)
            end
          end
        end
      end
    RUBY

    File.write(File.join(ext_dir, "patches/widget.rb"), <<~RUBY)
      module ExtKitchenWidgetPatch
        def render
          "patched"
        end
      end
      ExtKitchenFixture::WidgetTarget.prepend(ExtKitchenWidgetPatch)
    RUBY

    File.write(File.join(ext_dir, "hooks/audit.rb"), <<~RUBY)
      Clacky::ExtensionHookRegistry.add do |tool, *_args|
        ExtKitchenFixture.const_set(:LAST_TOOL, tool) if defined?(ExtKitchenFixture)
      end
    RUBY

    File.write(File.join(ext_dir, "runtime/noop.rb"), "# runtime adapter\n")
  end

  after do
    [builtin, installed, local, patches_dir].each { |d| FileUtils.remove_entry(d) if Dir.exist?(d) }
    Clacky::ExtensionLoader.instance_variable_set(:@last_result, nil)
    Clacky::ExtensionHookRegistry.clear!
  end

  it "loads every contributes type, verifies clean, and wires patches/hooks/channels" do
    result = Clacky::ExtensionLoader.load_all(
      layers: { builtin: builtin, installed: installed, local: local }
    )

    %i[panels api skills agents channels patches hooks providers agent_runtimes].each do |kind|
      list = result.public_send(kind)
      expect(list).not_to be_empty, "expected #{kind} to be populated, got #{list.inspect}"
    end

    issues = Clacky::ExtensionVerifier.verify(result)
    errors = issues.select { |i| i.level == :error }
    expect(errors).to be_empty, "verifier reported errors: #{errors.map(&:message).inspect}"

    Clacky::PatchLoader.load_all(dir: patches_dir)
    expect(ExtKitchenFixture::WidgetTarget.new.render).to eq("patched")

    Clacky::ExtensionHookLoader.load_all
    hook_manager = Clacky::HookManager.new
    Clacky::ExtensionHookRegistry.apply_to(hook_manager)
    hook_manager.trigger(:before_tool_use, "kitchen_tool", {})
    expect(ExtKitchenFixture::LAST_TOOL).to eq("kitchen_tool")

    Clacky::Channel::Adapters::ExtensionAdapterLoader.load_all
    expect(Clacky::Channel::Adapters.find(:noop_kitchen)).not_to be_nil
  end
end
