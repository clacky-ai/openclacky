# frozen_string_literal: true

RSpec.describe "WebUI homepage routing" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:app_js) { File.read(File.join(web_dir, "app.js")) }
  let(:index_html) { File.read(File.join(web_dir, "index.html")) }

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
end
