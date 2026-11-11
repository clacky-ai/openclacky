# frozen_string_literal: true

# "Download backup" only showed an indeterminate "Downloading…" because the
# page used fetch, which exposes no download progress. XHR reports it, and the
# server sends Content-Length, so the button can show a real percentage.
RSpec.describe "Web backup download progress" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:store)   { File.read(File.join(web_dir, "features/backup/store.js")) }
  let(:view)    { File.read(File.join(web_dir, "features/backup/view.js")) }
  let(:i18n_js) { File.read(File.join(web_dir, "i18n.js")) }

  it "downloads through XHR so progress events are available" do
    expect(store).to include('xhr.open("GET", "/api/backup/download")')
    expect(store).to include('xhr.responseType = "blob"')
    expect(store).to include("xhr.onprogress")
    expect(store).to include("e.lengthComputable")
  end

  it "renders the percentage while the archive is downloading" do
    expect(view).to match(/Backup\.fetchArchive\(\(loaded, total\) =>/)
    expect(view).to include('I18n.t("settings.backup.downloadingPct", { pct: pct })')
  end

  it "translates the percentage label" do
    expect(i18n_js).to include('"settings.backup.downloadingPct":    "Downloading {{pct}}%…"')
    expect(i18n_js).to include('"settings.backup.downloadingPct":    "正在下载 {{pct}}%…"')
  end
end
