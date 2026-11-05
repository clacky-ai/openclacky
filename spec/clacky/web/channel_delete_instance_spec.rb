# frozen_string_literal: true

RSpec.describe "Channel instance deletion" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)    { File.read(File.join(web_dir, "features/channels/view.js")) }
  let(:store)   { File.read(File.join(web_dir, "features/channels/store.js")) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }
  let(:server)  { File.read(File.expand_path("../../../lib/clacky/server/http_server.rb", __dir__)) }
  let(:config)  { File.read(File.expand_path("../../../lib/clacky/server/channel/channel_config.rb", __dir__)) }

  it "offers a destructive delete item in the row menu, matching the other row menus" do
    expect(view).to include('item("delete", I18n.t("channels.btn.delete"), true)')
    expect(view).not_to include("ext-row-menu-divider")
    expect(view).to match(/else if \(kind === "delete"\) _onDeleteInstance\(platform, instanceId\)/)
  end

  it "asks for confirmation before deleting" do
    body = view[/async function _onDeleteInstance\(platform, instanceId\) \{(.*?)\n  \}/m, 1]
    expect(body).not_to be_nil
    expect(body).to include('Modal.confirm(I18n.t("channels.confirm.deleteInstance", { name: label }))')
    expect(body.index("Modal.confirm")).to be < body.index("Channels.remove")
  end

  it "sends DELETE to the instance endpoint and reloads the list" do
    body = store[/async remove\(platform, instanceId\) \{(.*?)\n    \},/m, 1]
    expect(body).not_to be_nil
    expect(body).to include("method: \"DELETE\"")
    expect(body).to include("/api/channels/${encodeURIComponent(platform)}/instances/${encodeURIComponent(id)}")
    expect(body).to include("Channels.load({ silent: true })")
  end

  it "removes the instance from channels.yml instead of only disabling it" do
    body = server[/def api_delete_channel\(platform, res, instance_id = nil\)(.*?)\n      end/m, 1]
    expect(body).not_to be_nil
    expect(body).to include("config.remove_platform(platform, instance_id)")
    expect(body).not_to include("disable_platform")
  end

  it "translates the delete menu, confirmation and toast in both locales" do
    %w[channels.btn.delete channels.confirm.deleteInstance channels.toast.deleted channels.toast.deleteFail].each do |key|
      expect(i18n.scan(/^\s+"#{Regexp.escape(key)}":/).size).to eq(2)
    end
    expect(i18n).to include("删除「{{name}}」？")
    expect(config).to include("def remove_platform")
  end
end
