# frozen_string_literal: true

RSpec.describe "Web tooltip translations" do
  let(:index) { File.read(File.expand_path("../../../lib/clacky/web/index.html", __dir__)) }
  let(:i18n) { File.read(File.expand_path("../../../lib/clacky/web/i18n.js", __dir__)) }

  let(:en_keys) { i18n[/\n    en: \{\n(.*?)\n    \},/m, 1].scan(/^\s+"([\w.]+)":/).flatten }
  let(:zh_keys) { i18n[/\n    zh: \{\n(.*?)\n    \}\n  \};/m, 1].scan(/^\s+"([\w.]+)":/).flatten }

  def button_tag(id)
    index[/<button id="#{Regexp.escape(id)}"[^>]*>/]
  end

  it "translates the send tooltip on both composers" do
    %w[new-session-send btn-send].each do |id|
      expect(button_tag(id)).to include('data-i18n-title="chat.btn.sendTitle"'), id
    end
  end

  it "translates the stop tooltip" do
    expect(button_tag("btn-interrupt")).to include('data-i18n-title="chat.btn.stopTitle"')
  end

  it "routes the attach and skill buttons through the shared tooltip" do
    %w[ns-btn-attach btn-attach].each do |id|
      expect(button_tag(id)).to include('data-i18n-tooltip="tooltip.attach"'), id
      expect(button_tag(id)).to include("data-tooltip="), id
      expect(button_tag(id)).not_to include("title="), id
    end
    %w[ns-btn-slash btn-slash].each do |id|
      expect(button_tag(id)).to include('data-i18n-tooltip="tooltip.slash"'), id
      expect(button_tag(id)).not_to include("title="), id
    end
  end

  it "routes the four session info bar pills through the shared tooltip" do
    {
      "sib-dir" => "sib.dir.tooltip",
      "sib-model" => "sib.model.tooltip",
      "sib-reasoning" => "sib.reasoning.tooltip",
      "sib-mode" => "sib.mode.tooltip"
    }.each do |id, key|
      tag = index[/<(?:span|button) id="#{Regexp.escape(id)}"[^>]*>/]
      expect(tag).to include(%(data-i18n-tooltip="#{key}")), id
      expect(tag).to include("data-tooltip="), id
      expect(tag).not_to include("title="), id
    end
  end

  it "keeps the info bar tooltips in sync when the language changes" do
    sessions = File.read(File.expand_path("../../../lib/clacky/web/sessions.js", __dir__))
    settings = File.read(File.expand_path("../../../lib/clacky/web/settings.js", __dir__))
    %w[sibDir sibModel sibMode].each do |var|
      expect(sessions).not_to match(/#{var}\.title\s*=/), var
    end
    %w[sibModel sibMode].each do |var|
      expect(sessions).to include(var + '.setAttribute("data-tooltip",'), var
    end
    # The directory tooltip is a plain static label now, so applyAll owns it.
    expect(sessions).not_to include("sibDir.setAttribute")
    expect(settings).to match(/I18n\.setLang\(btn\.dataset\.lang\);[\s\S]{0,300}Sessions\.updateInfoBar/)
  end

  it "never leaves a static title attribute in English" do
    untranslated = index.scan(/<[^>\n]*\stitle="[^"]*"[^>]*>/).reject { |tag| tag.include?("data-i18n-title") }
    expect(untranslated).to be_empty
  end

  it "resolves every tooltip key in both locales" do
    used = index.scan(/data-i18n-(?:title|tooltip)="([\w.]+)"/).flatten.uniq
    expect(used).not_to be_empty
    missing = used.reject { |key| en_keys.include?(key) && zh_keys.include?(key) }
    expect(missing).to be_empty
  end

  it "applies data-i18n-tooltip through applyAll" do
    expect(i18n).to include('querySelectorAll("[data-i18n-tooltip]")')
    expect(i18n).to include('el.setAttribute("data-tooltip", t(key, vars))')
  end

  it "translates the attachment remove tooltip" do
    %w[sessions.js features/new-session/view.js].each do |file|
      source = File.read(File.expand_path("../../../lib/clacky/web/#{file}", __dir__))
      expect(source).not_to include('removeBtn.title = "Remove"'), file
      expect(source).to include('I18n.t("tooltip.remove")'), file
    end
  end
end
