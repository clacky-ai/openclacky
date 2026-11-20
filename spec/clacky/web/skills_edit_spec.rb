# frozen_string_literal: true

RSpec.describe "Skills edit form feedback" do
  let(:root)  { File.expand_path("../../..", __dir__) }
  let(:web)   { File.join(root, "lib/clacky/web") }
  let(:view)  { File.read(File.join(web, "features/skills/view.js")) }
  let(:store) { File.read(File.join(web, "features/skills/store.js")) }
  let(:i18n)  { File.read(File.join(web, "i18n.js")) }
  let(:server) { File.read(File.join(root, "lib/clacky/server/http_server.rb")) }

  it "confirms a successful save with a toast" do
    expect(i18n).to include('"skills.edit.saved":          "Skill saved"')
    expect(i18n).to include('"skills.edit.saved":          "技能已保存"')
    expect(view).to include('Modal.toast(I18n.t("skills.edit.saved"), "success");')
  end

  it "follows a renamed skill to its new detail page instead of the list" do
    # The PUT answers with the identifier the reloaded skill now has, because
    # `name` is the identity and renaming it invalidates the old detail key.
    expect(server).to include('renamed  = fields.is_a?(Hash) ? @skill_loader[fields["name"].to_s] : nil')
    expect(server).to include("new_name = renamed ? renamed.identifier : skill.identifier")
    expect(store).to include("return { ok: true, name: data.name || name };")
    expect(view).to include("if (r.name && r.name !== skill.name) _openDetail(r.name);")
  end
end
