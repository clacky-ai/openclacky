# frozen_string_literal: true

RSpec.describe "Directory picker localization" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:sessions) { File.read(File.join(web_dir, "sessions.js")) }
  let(:i18n) { File.read(File.join(web_dir, "i18n.js")) }

  it "uses friendly labels for both directory rows and breadcrumbs" do
    expect(sessions).to include(
      "name.textContent = friendlyDirectoryName(entry.absPath, entry.name)"
    )
    expect(sessions).to include(
      "seg.textContent = friendlyDirectoryName(targetPath, part)"
    )
  end

  it "recognizes macOS and WSL native locations without replacing real paths" do
    expect(sessions).to include('context.os === "macos"')
    expect(sessions).to include('context.os === "wsl"')
    expect(sessions).to include('const path = String(absPath || "")')
    expect(sessions).to include("entry.absPath")
  end

  it "provides English and Chinese names for common OS folders" do
    expect(i18n).to include('"sib.dir.location.desktop":      "Desktop"')
    expect(i18n).to include('"sib.dir.location.desktop":      "桌面"')
    expect(i18n).to include('"sib.dir.location.users":        "用户"')
    expect(i18n).to include('"sib.dir.location.documentsMac": "文稿"')
    expect(i18n).to include('"sib.dir.location.documents":    "文档"')
  end
end
