# frozen_string_literal: true

# Publishing used to live only in the creator studio (ext-studio). It now
# belongs to the "My Skills" detail page, so these guards keep the flow from
# drifting away from the host endpoints the studio already used.
RSpec.describe "Skills publish UI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)    { File.read(File.join(web_dir, "features/skills/view.js")) }
  let(:store)   { File.read(File.join(web_dir, "features/skills/store.js")) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }
  let(:styles)  { File.read(File.join(web_dir, "app.css")) }

  it "reads the same cloud listing the creator studio used" do
    expect(store).to include('fetch("/api/creator/skills"')
    expect(store).to include("cloud_skills")
    expect(store).to include("has_local_changes")
  end

  it "publishes through the host endpoint, including the force overwrite" do
    expect(store).to include('const url = `/api/my-skills/${encodeURIComponent(name)}/publish${force ? "?force=true" : ""}`;')
    expect(store).to include('method: "POST"')
    expect(store).to include("alreadyExists")
  end

  it "renders the publish block on a custom skill's detail page" do
    expect(view).to include("${_publishBlock(skill)}")
    expect(view).to include('data-publish-mode="publish"')
    expect(view).to include('data-publish-mode="update"')
    expect(view).to include('I18n.t("skills.publish.upToDate")')
  end

  it "leaves system and invalid skills out of the publish flow" do
    expect(view).to include("function _publishBlock(skill) {")
    expect(view).to include('if (_isSystem(skill) || skill.invalid) return "";')
  end

  it "confirms before overwriting a same-named cloud skill" do
    expect(view).to include("result.alreadyExists")
    expect(view).to include('I18n.t("skills.publish.overwrite", { name: skill.name })')
  end

  it "explains the creator license instead of failing after a click" do
    expect(view).to include('data-publish-mode="locked"')
    expect(view).to include('Modal.toast(I18n.t("skills.publish.locked"), "error")')
  end

  it "keeps a local copy that is newer than the upload updatable" do
    expect(store).to include("hasLocalChanges: !!(cloud.has_local_changes && cloud.local_present)")
    expect(view).to include('data-publish-mode="update"')
  end

  it "keeps both languages in sync" do
    %w[action update upToDate publishing published unpublished changed
       downloads locked overwrite done updated failed].each do |key|
      expect(i18n.scan(%("skills.publish.#{key}":)).size).to eq(2)
    end
  end

  it "styles the status row" do
    expect(styles).to include(".skill-publish {")
    expect(styles).to include(".skill-publish-badge.is-changed")
    expect(styles).to include(".skill-publish-btn")
  end

  # `name` doubles as the slash command and the publish slug. The platform only
  # accepts lowercase letters, digits and hyphens, so the skill form rejects a
  # display name typed there (e.g. "中英翻译") instead of saving it silently and
  # failing later at publish time.
  describe "skill name validation" do
    it "rejects a non-slug name when saving the skill form" do
      expect(view).to include("/^[a-z0-9][a-z0-9-]{0,63}$/.test(name)")
      expect(view).to include('I18n.t("skills.edit.nameInvalid")')
    end

    it "keeps both languages in sync for the new string" do
      expect(i18n.scan(%("skills.edit.nameInvalid":)).size).to eq(2)
    end
  end
end
