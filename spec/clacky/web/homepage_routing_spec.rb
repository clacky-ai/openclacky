# frozen_string_literal: true

RSpec.describe "WebUI homepage routing" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:app_js) { File.read(File.join(web_dir, "app.js")) }
  let(:index_html) { File.read(File.join(web_dir, "index.html")) }
  let(:settings_js) { File.read(File.join(web_dir, "settings.js")) }
  let(:i18n_js) { File.read(File.join(web_dir, "i18n.js")) }
  let(:ext_js) { File.read(File.join(web_dir, "core", "ext.js")) }

  it "keeps #new mapped to the welcome view" do
    expect(app_js).to match(/h === ["']new["'].+view: ["']welcome["']/)
  end

  it "resolves an extension homepage only in the welcome branch" do
    welcome = app_js[/default:\s+\/\/ "welcome".*?\n\s+break;/m]
    expect(welcome).not_to be_nil, "could not locate the Router welcome branch"
    expect(welcome).to include("resolveHomepage")
    expect(welcome).to include('_apply("ext-workspace"')
  end

  it "sends the host logo to welcome" do
    expect(index_html).to include(%(onclick="Router.navigate('welcome')"))
    expect(index_html).not_to include(%(onclick="Router.navigate('chat')"))
  end

  it "offers host-owned save and restore controls when candidates exist" do
    expect(index_html).to include('id="settings-homepage-section"')
    expect(index_html).to include('value="auto"')
    expect(index_html).to include('value="native"')
    expect(index_html).to include('id="btn-save-default-homepage"')
    expect(index_html).to include('id="btn-restore-default-homepage"')
    expect(settings_js).to include("homepageCandidates()")
    expect(settings_js).to include("selectHomepage(value)")
    expect(settings_js).to include("selectHomepage(null)")
  end

  it "loads and saves the homepage preference through client settings" do
    expect(ext_js).to include('fetch("/api/config/settings")')
    expect(ext_js).to include('method: "PATCH"')
    expect(ext_js).to include("default_homepage")
    expect(ext_js).not_to include("HOMEPAGE_STORAGE_KEY")
    expect(ext_js).not_to match(/localStorage\.(?:getItem|setItem)\([^\n]*homepage/)
    expect(app_js).to include("await Clacky.ext.ui.loadHomepagePreference()")
  end

  it "localizes the homepage setting" do
    expect(i18n_js.scan('"settings.homepage.title"').length).to eq(2)
    expect(i18n_js.scan('"settings.homepage.auto"').length).to eq(2)
    expect(i18n_js.scan('"settings.homepage.native"').length).to eq(2)
    expect(i18n_js.scan('"settings.homepage.save"').length).to eq(2)
    expect(i18n_js.scan('"settings.homepage.restore"').length).to eq(2)
  end
end
