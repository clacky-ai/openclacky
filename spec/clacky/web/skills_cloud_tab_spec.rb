# frozen_string_literal: true

# The cloud skill listing lived in the creator studio (ext-studio) only. It now
# has its own tab on the skills page, backed by the same host endpoint, so these
# guards keep the two from drifting apart.
RSpec.describe "Skills cloud tab" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:html)    { File.read(File.join(web_dir, "index.html")) }
  let(:view)    { File.read(File.join(web_dir, "features/skills/view.js")) }
  let(:store)   { File.read(File.join(web_dir, "features/skills/store.js")) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }
  let(:styles)  { File.read(File.join(web_dir, "app.css")) }

  it "adds the tab button and its own content pane" do
    expect(html).to include('data-tab="cloud-skills" id="tab-cloud-skills"')
    expect(html).to include('id="skills-tab-cloud"')
    expect(html).to include('id="cloud-skills-list"')
  end

  it "shows the pane only for the cloud tab" do
    expect(view).to include('const tabCloud = $("skills-tab-cloud");')
    expect(view).to include('tab === "cloud-skills" ? "" : "none"')
  end

  it "loads the listing when the tab is opened" do
    expect(store).to include('if (tab === "cloud-skills") Skills.ensurePublishState();')
    expect(view).to include('if (SkillsStore.state.activeTab === "cloud-skills") {')
  end

  it "re-renders when the listing arrives or a publish refreshes it" do
    expect(view).to include('Skills.on("publish:changed"')
    expect(view).to include("if (SkillsStore.state.activeTab === \"cloud-skills\") _renderCloudSkills();")
    expect(view).to include('if (p.tab === "cloud-skills") _renderCloudSkills();')
  end

  it "lists published skills with version, downloads and change marker" do
    expect(view).to include("function _renderCloudSkillTile(skill)")
    expect(view).to include('I18n.t("skills.publish.published")')
    expect(view).to include('I18n.t("skills.publish.changed")')
    expect(view).to include('I18n.t("skills.publish.downloads")')
    expect(view).to include("v${escapeHtml(skill.version)}")
  end

  it "offers Update only when the local copy moved past the upload" do
    expect(view).to include('if (skill.local_present && skill.has_local_changes) {')
    expect(view).to include('I18n.t("skills.publish.update")')
    expect(view).to include('I18n.t("skills.publish.upToDate")')
    expect(view).to include("Skills.publishSkill(name, { force: true })")
  end

  it "keeps iterate as a menu entry and hides it without a local copy" do
    expect(view).to include("if (skill.local_present) {")
    expect(view).to include('I18n.t("skills.cloud.btn.iterate")')
    expect(view).to include('`/skill-creator ${I18n.t("skills.cloud.iteratePrompt")}${name}`')
  end

  # Unpublish must be reachable even when the folder is gone locally — otherwise
  # a skill deleted on disk would be stuck in the marketplace forever.
  it "offers unpublish on every cloud card behind a destructive confirm" do
    expect(view).to include('I18n.t("skills.cloud.btn.unpublish")')
    expect(view).to include("run: () => _unpublishCloudSkill(name), danger: true")
    expect(view).to include('Modal.confirm(I18n.t("skills.cloud.unpublishConfirm", { name }))')
    expect(view).to include('I18n.t("skills.cloud.unpublished"')
  end

  it "deletes through the host route and refreshes the listing" do
    expect(store).to include("async unpublishSkill(name)")
    expect(store).to include('`/api/my-skills/${encodeURIComponent(name)}`, { method: "DELETE" }')
    expect(store).to include("await Skills.ensurePublishState({ force: true });")
  end

  it "explains the empty, unlicensed and failed states" do
    expect(view).to include('I18n.t("skills.cloud.empty")')
    expect(view).to include('I18n.t("skills.cloud.locked")')
    expect(view).to include('I18n.t("skills.cloud.loadFailed")')
    expect(view).to include("if (pub.licensed === false) {")
  end

  it "asks the reader to publish rather than talking about a creator licence" do
    expect(i18n).to include('"skills.cloud.locked":        "发布技能后，这里会列出你发布过的技能。"')
    expect(i18n).to include('"skills.cloud.locked":        "Publish a skill and it shows up here."')
    expect(i18n).to include('"skills.tab.cloud":           "我发布的技能"')
    expect(i18n).to include('"skills.tab.cloud":           "My Published Skills"')
    expect(i18n).not_to include("查看云端技能需要创作者授权")
    expect(i18n).not_to include("A creator license is required to see your cloud skills")
  end

  it "drops the cloud-skills wording from the tab and its hints" do
    %w[skills.tab.cloud skills.cloud.locked skills.cloud.loadFailed].each do |key|
      lines = i18n.lines.select { |line| line.include?(%("#{key}":)) }
      expect(lines.size).to eq(2)
      lines.each { |line| expect(line).not_to include("云端技能", "Cloud Skills") }
    end
  end

  it "searches inside the cloud list, not the other tabs" do
    expect(view).to include('const listId = tab === "my-skills" ? "skills-list"')
    expect(view).to include('tab === "cloud-skills" ? "cloud-skills-list"')
  end

  it "keeps both languages in sync" do
    %w[tab.cloud cloud.empty cloud.locked cloud.loadFailed
       cloud.btn.iterate cloud.iteratePrompt cloud.btn.unpublish
       cloud.unpublishConfirm cloud.unpublishFailed cloud.unpublished].each do |key|
      expect(i18n.scan(%("skills.#{key}":)).size).to eq(2)
    end
  end

  # I18n.t only rewrites `{{key}}` — a bare `{name}` reaches the UI verbatim.
  # (The extension delete dialogs shipped with this bug once already.)
  it "interpolates a skill name with the {{name}} form only" do
    expect(i18n).to include("「{{name}}」")
    expect(i18n).to include('\"{{name}}\\"')
    expect(i18n).not_to match(/(?<!\{)\{name\}(?!\})/)
  end

  it "styles the cloud tile extras" do
    expect(styles).to include(".skill-cloud-meta {")
    expect(styles).to include(".skill-cloud-update {")
    expect(styles).to include(".skill-cloud-uptodate {")
  end

  # The tiles used to sit flush against the tab underline: the other two lists
  # carry this top gap, the cloud one was added without it.
  it "keeps the same top gap as the other skill lists" do
    expect(styles).to match(/#cloud-skills-list \{\s*padding-top: 1\.25rem;/)
    expect(styles).to match(/#brand-skills-list \{\s*padding-top: 1\.25rem;/)
  end
end
