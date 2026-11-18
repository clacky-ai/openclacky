# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"

RSpec.describe "Channel instance rename" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)    { File.read(File.join(web_dir, "features/channels/view.js")) }
  let(:store)   { File.read(File.join(web_dir, "features/channels/store.js")) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }
  let(:server)  { File.read(File.expand_path("../../../lib/clacky/server/http_server.rb", __dir__)) }

  it "adds a non-destructive rename item above the setup/delete entries" do
    rename_item = %q{item("rename", I18n.t("channels.btn.rename"))}
    expect(view).to include(rename_item)
    expect(view).not_to include(%q{item("rename", I18n.t("channels.btn.rename"), true)})
    expect(view.index(rename_item)).to be < view.index(%q{item("setup"})
    expect(view.index(rename_item)).to be < view.index(%q{item("delete"})
    expect(view).to match(/else if \(kind === "rename"\) _onRenameInstance\(platform, instanceId\)/)
  end

  it "asks for the new name before hitting the API, and skips a no-op" do
    body = view[/async function _onRenameInstance\(platform, instanceId\) \{(.*?)\n  \}/m, 1]
    expect(body).not_to be_nil
    expect(body).to include(%q{Modal.prompt(I18n.t("channels.prompt.rename")})
    expect(body.index("Modal.prompt")).to be < body.index("Channels.rename")
    expect(body).to include("if (name === null) return;")
    expect(body).to include("if (name === current) return;")
  end

  it "seeds the prompt with the label the row is showing" do
    body = view[/async function _onRenameInstance\(platform, instanceId\) \{(.*?)\n  \}/m, 1]
    expect(body).not_to be_nil
    expect(body).to include("current || meta.name")
  end

  it "patches the instance endpoint instead of the whole platform" do
    body = store[/async rename\(platform, instanceId, name\) \{(.*?)\n    \},/m, 1]
    expect(body).not_to be_nil
    expect(body).to include(%q{method:  "PATCH"})
    expect(body).to include(%q{/api/channels/${encodeURIComponent(platform)}/instances/${encodeURIComponent(id)}})
    expect(body).to include("Channels.load({ silent: true })")
  end

  it "routes PATCH /api/channels/:platform/instances/:id to the rename handler" do
    expect(server).to match(
      %r{elsif method == "PATCH" && path\.match\?\(%r\{\^/api/channels/\[\^/\]\+/instances/\[\^/\]\+\$\}\)(.*?)api_rename_channel\(platform, instance_id, req, res\)}m
    )
  end

  it "rejects blank and over-long names before touching the config" do
    body = server[/def api_rename_channel\(platform, instance_id, req, res\)(.*?)\n      end/m, 1]
    expect(body).not_to be_nil
    expect(body.index("name is required")).to be < body.index("config.save")
    expect(body).to include("MAX_INSTANCE_NAME_LENGTH")
    expect(server).to include("MAX_INSTANCE_NAME_LENGTH = 40")
  end

  it "renames an existing instance and never creates one" do
    config = Clacky::ChannelConfig.new(
      channels: { "feishu" => [{ "id" => "default", "name" => "", "enabled" => true, "app_id" => "cli_x" }] }
    )

    expect(config.rename_instance(:feishu, "default", "  主机器人  ")).to be true
    expect(config.instance(:feishu, "default")["name"]).to eq("主机器人")
    expect(config.instance(:feishu, "default")["app_id"]).to eq("cli_x")

    expect(config.rename_instance(:feishu, "missing", "x")).to be false
    expect(config.rename_instance(:discord, "default", "x")).to be false
    expect(config.instances(:feishu).size).to eq(1)
    expect(config.instances(:discord)).to be_empty
  end

  it "ellipsizes a long custom name instead of stretching the row" do
    css = File.read(File.join(web_dir, "app.css"))
    rule = css[/\.channel-row-title \{(.*?)\}/m, 1]
    expect(rule).not_to be_nil
    expect(rule).to include("text-overflow: ellipsis")
    expect(rule).to include("overflow: hidden")
    expect(view).to include(%q{<span class="channel-row-title" title="${_esc(title)}">})
  end

  it "translates the menu item, prompt and toasts in both locales" do
    %w[
      channels.btn.rename channels.prompt.rename
      channels.toast.renamed channels.toast.renameFail
    ].each do |key|
      expect(i18n.scan(/^\s+"#{Regexp.escape(key)}":/).size).to eq(2)
    end
    expect(i18n).to include("修改名称")
    expect(i18n).to include("Rename")
  end
end
