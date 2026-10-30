# frozen_string_literal: true

RSpec.describe "Toolbar tooltips" do
  let(:root)      { File.expand_path("../../..", __dir__) }
  let(:workspace) { File.read(File.join(root, "lib/clacky/web/features/workspace/view.js")) }
  let(:git)       { File.read(File.join(root, "lib/clacky/default_extensions/git/panels/git/view.js")) }
  let(:i18n)      { File.read(File.join(root, "lib/clacky/web/i18n.js")) }

  describe "file panel toolbar" do
    it "hints the action buttons through the shared tooltip" do
      expect(workspace).to include('btn.setAttribute("data-tooltip", t(key));')
      expect(workspace).to include('btn.setAttribute("data-i18n-tooltip", key);')
      # The tab button keeps a native title: it truncates the file path.
      expect(workspace).not_to include("btn.title = t(")
    end

    it "passes an i18n key to every action button" do
      callers = workspace.scan(/actionBtn\(ICON_[A-Z_]+, ("[^"]+")/).flatten
      expect(callers).to contain_exactly(
        %("workspace.toggleTree"),
        %("workspace.backToFiles"),
        %("workspace.preview"),
        %("workspace.splitPreview"),
        %("workspace.copyContent"),
        %("modal.save"),
        %("workspace.openWithMenu"),
        %("workspace.zoomOut"),
        %("workspace.zoomIn"),
        %("workspace.zoomFit")
      )
    end

    it "routes the open-with split button hint through the tooltip as well" do
      expect(workspace).to include('openMainBtn.setAttribute("data-tooltip", hint);')
      expect(workspace).to include('openMainBtn.setAttribute("aria-label", hint);')
      expect(workspace).not_to include("openMainBtn.title")
      expect(workspace.scan("setOpenHint(").length).to eq(3)
    end

    it "hints the tree bar and tab close buttons" do
      expect(workspace).to include('refresh.setAttribute("data-tooltip", t("workspace.refresh"));')
      expect(workspace).to include('refresh.setAttribute("data-i18n-tooltip", "workspace.refresh");')
      expect(workspace).to include('searchClear.setAttribute("data-tooltip", t("workspace.closeTab"));')
      expect(workspace).to include('close.setAttribute("data-tooltip", t("workspace.closeTab"));')
    end
  end

  describe "git panel toolbar" do
    it "hints the layout, wrap and tree toggles through the shared tooltip" do
      expect(git).to include('btn.setAttribute("data-tooltip", hint);')
      expect(git.scan('btn.setAttribute("data-tooltip", label);').length).to eq(3)
      expect(git).not_to include("btn.title =")
    end

    it "hints the session aside buttons through the shared tooltip" do
      %w[
        changes.expandAll
        changes.refresh
        changes.find.title
      ].each do |key|
        expect(git).to include('"data-tooltip": t("' + key + '",')
        expect(git).not_to include('title: t("' + key + '",')
      end
    end
  end

  describe "session aside header" do
    let(:html)  { File.read(File.join(root, "lib/clacky/web/index.html")) }
    let(:aside) { File.read(File.join(root, "lib/clacky/web/core/aside.js")) }

    it "hints the fullscreen and collapse buttons through the shared tooltip" do
      expect(html).to include('<button id="btn-aside-fullscreen" class="session-aside-fullscreen" data-tooltip="Fullscreen preview" data-tooltip-pos="bottom">')
      expect(html).to include('<button id="btn-aside-collapse" class="session-aside-collapse" data-tooltip="Collapse panel" data-tooltip-pos="bottom">')
      expect(html).not_to include(%(id="btn-aside-fullscreen" class="session-aside-fullscreen" data-i18n-title))
      expect(html).not_to include(%(id="btn-aside-collapse" class="session-aside-collapse" title=))
    end

    it "keeps the shortcut suffix and the fullscreen label in sync on lang switches" do
      expect(aside).to include('collapse.setAttribute("data-tooltip", label("aside.collapse"));')
      expect(aside).to include('opener.setAttribute("data-tooltip", label("aside.expand"));')
      expect(aside).to include('btn.setAttribute("data-tooltip", Clacky.I18n.t(isFullscreen() ? "aside.exitFullscreen" : "aside.fullscreen"));')
      expect(aside).not_to include("btn.title")
      expect(aside.scan('document.addEventListener("langchange"').length).to eq(2)
    end
  end

  describe "top header" do
    let(:html) { File.read(File.join(root, "lib/clacky/web/index.html")) }
    let(:notify) { File.read(File.join(root, "lib/clacky/web/components/notify.js")) }

    it "hints the command bar, receipt and alert buttons through the shared tooltip" do
      expect(html).to include('data-tooltip="Search sessions" data-tooltip-pos="bottom" data-i18n-tooltip="header.cmdbar.placeholder"')
      expect(html).to include('data-tooltip="Print receipt" data-tooltip-pos="bottom" data-i18n-tooltip="billing.share.btn"')
      expect(html).to include('data-tooltip="Task alerts" data-tooltip-pos="left" data-i18n-tooltip="notify.tooltip.off"')
      expect(html).not_to include('id="header-cmdbar" type="button" title=')
      expect(html).not_to include('id="header-print-receipt" class="theme-toggle-btn" data-i18n-title')
      expect(html).not_to include('id="notify-toggle-header" class="theme-toggle-btn" data-i18n-title')
      expect(html).to include('id="btn-toggle-sidebar" class="sidebar-toggle-btn" data-tooltip="Toggle sidebar" data-tooltip-pos="right" data-i18n-tooltip="tooltip.toggleSidebar"')
      expect(html).not_to include('id="btn-toggle-sidebar" class="sidebar-toggle-btn" title=')
    end

    it "rewrites the alert tooltip in place when the toggle flips" do
      expect(notify).to include('btn.setAttribute("data-tooltip", tip);')
      expect(notify).to include('btn.setAttribute("data-i18n-tooltip", _tooltipKey(on));')
      expect(notify).not_to include("btn.title =")
      expect(notify).not_to include('btn.setAttribute("data-i18n-title"')
    end
  end

  it "keeps every key the toolbars look up in both locales" do
    %w[
      changes.expandAll
      changes.refresh
      changes.find.title
      workspace.refresh
      workspace.closeTab
      header.cmdbar.placeholder
      billing.share.btn
      notify.tooltip.off
      tooltip.toggleSidebar
    ].each do |key|
      expect(i18n.scan(%("#{key}":)).length).to eq(2), "#{key} is missing from a locale"
    end
  end
end
