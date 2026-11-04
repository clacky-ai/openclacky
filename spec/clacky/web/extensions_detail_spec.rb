# frozen_string_literal: true

RSpec.describe "Extensions detail UI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)   { File.read(File.join(web_dir, "features/extensions/view.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }

  it "prefers a real icon in the detail hero, then emoji, then a letter" do
    expect(view).to include("const detailIconHtml = ext.icon_url")
    expect(view).to include('<img class="extension-detail-img"')
    expect(view).to include("${detailIconHtml}")
    expect(styles).to match(/\.extension-detail-img \{[^}]*object-fit: cover;/m)
  end

  it "shows what the extension contributes" do
    expect(view).to include("${_renderContributes(ext.contributes)}")
  end

  it "opens the manifest-backed detail from an official row" do
    expect(view).to include('row.classList.add("extension-row-clickable");')
    expect(view).not_to include('if (ext.layer !== "builtin") row.classList.add("extension-row-clickable")')
    expect(view).to include('const isBuiltin = !!(known && known.layer === "builtin");')
    expect(view).to include("const isBrand = !isBuiltin && (")
  end
end
