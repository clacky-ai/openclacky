# frozen_string_literal: true

# Restoring a backup used to die on large archives: the page read the whole
# file into an ArrayBuffer before uploading, so WebKit killed the web process
# on ~300MB archives. The upload has to stay a stream end to end.
RSpec.describe "Web backup restore upload" do
  let(:web_dir)  { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:store)    { File.read(File.join(web_dir, "features/backup/store.js")) }
  let(:view)     { File.read(File.join(web_dir, "features/backup/view.js")) }
  let(:i18n_js)  { File.read(File.join(web_dir, "i18n.js")) }

  it "never buffers the archive in the web process" do
    expect(store).not_to include("arrayBuffer")
    expect(view).not_to include("arrayBuffer")
  end

  it "hands the File to XHR so the browser streams it from disk" do
    expect(store).to include("xhr.send(file)")
    expect(store).to include("xhr.upload.onprogress")
    expect(view).to match(/Backup\.restore\(file,/)
  end

  it "shows upload progress while the archive is in flight" do
    expect(i18n_js).to include('"settings.backup.uploading"')
    expect(view).to include('I18n.t("settings.backup.uploading"')
  end
end
