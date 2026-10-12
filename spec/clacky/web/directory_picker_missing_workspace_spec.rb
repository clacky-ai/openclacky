# frozen_string_literal: true

RSpec.describe "Directory picker with a missing workspace" do
  let(:sessions) do
    File.read(File.expand_path("../../../lib/clacky/web/sessions.js", __dir__))
  end
  let(:i18n) do
    File.read(File.expand_path("../../../lib/clacky/web/i18n.js", __dir__))
  end

  it "uses the session-independent browser for absolute paths" do
    expect(sessions).to match(
      /async function fetchDirs\(relPath, absolute = false\).*?if \(sessionLess \|\| absolute\) \{.*?`\/api\/dirs/m
    )
  end

  it "opens the bound path directly so the picker can detect that it is missing" do
    expect(sessions).to include('navigateTo(currentDir || "/", true);')
    expect(sessions).not_to include('navigateTo("", false).then((loaded) => {')
  end

  it "keeps a missing bound path visible without selecting the backend fallback" do
    expect(sessions).to include("const displayPath = exactMatch ? effectivePath : dirPath;")
    expect(sessions).to include("setSelectedPath(exactMatch ? effectivePath : null);")
    expect(sessions).to include('t("sib.dir.missing", "This folder no longer exists. Please select a new working directory.")')
    expect(sessions).not_to include("selectedPath = effectivePath;")
  end

  it "requires an existing directory to be selected before confirmation" do
    expect(sessions).to include("let selectedPath = null;")
    expect(sessions).to include("confirmButton.disabled = true;")
    expect(sessions).to include("newFolderBtn.disabled = !exactMatch;")
  end

  it "explains the missing directory in both supported languages" do
    expect(i18n).to include(
      '"sib.dir.missing":         "This folder no longer exists. Please select a new working directory."'
    )
    expect(i18n).to include(
      '"sib.dir.missing":         "该文件夹已不存在，请重新选择工作目录。"'
    )
  end
end
