# frozen_string_literal: true

RSpec.describe "File Recall card action buttons" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)    { File.read(File.join(web_dir, "features/trash/view.js")) }
  let(:styles)  { File.read(File.join(web_dir, "app.css")) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }

  it "renders both card actions as icon-only buttons" do
    expect(view.scan(/class="btn-trash-(?:session-)?(?:restore|delete)"/).size).to eq(4)
    # Labels repeat on every row of the list, so they only live in the tooltip now.
    expect(view).not_to include('_t("trash.restore")}</span>')
    expect(view).not_to include('_t("trash.delete")}</span>')
    expect(view).not_to include('_t("trash.restoreSession")}</span>')
    expect(view).not_to include('_t("trash.deleteSession")}</span>')
  end

  it "keeps an accessible name on every icon button" do
    expect(view.scan(/class="btn-trash-(?:session-)?(?:restore|delete)"[^>]*aria-label=/).size).to eq(4)
  end

  it "sizes the file and session buttons with one shared rule" do
    block = styles[/\.btn-trash-restore,\s*\.btn-trash-delete,\s*\.btn-trash-session-restore,\s*\.btn-trash-session-delete\s*\{[^}]*\}/]
    expect(block).not_to be_nil
    expect(block).to include("width: 1.875rem", "height: 1.875rem", "border-radius: 6px", "background: transparent")

    glyphs = styles[/\.btn-trash-restore svg,\s*\.btn-trash-delete svg,\s*\.btn-trash-session-restore svg,\s*\.btn-trash-session-delete svg\s*\{[^}]*\}/]
    expect(glyphs).to include("width: 0.8125rem", "height: 0.8125rem")

    # The old per-button paddings are what made the two buttons look unrelated.
    expect(styles).not_to include(".btn-trash-delete {\n  padding:")
  end

  it "gives every toolbar control the same shape" do
    block = styles[/\.trash-filter-project-wrap,\s*\.btn-trash-action\s*\{[^}]*\}/]
    expect(block).not_to be_nil
    # Exact values are pinned in toolbar_control_size_spec — here it only matters
    # that one rule still covers both control types.
    expect(block).to include("height:", "border-radius:", "font-size:")
  end

  it "hovers the restore action in the theme colour and reserves red for delete" do
    restore = styles[/\.btn-trash-restore:hover:not\(:disabled\),\s*\.btn-trash-session-restore:hover:not\(:disabled\)\s*\{[^}]*\}/]
    expect(restore).not_to be_nil
    expect(restore).not_to include("--color-success")
    expect(restore).to include("border-color: var(--color-accent-primary)", "color: var(--color-accent-primary)")
    # The grey wash read as a disabled state next to the accent-coloured cards.
    expect(restore).not_to include("--color-bg-hover")

    delete = styles[/\.btn-trash-delete:hover:not\(:disabled\),\s*\.btn-trash-session-delete:hover:not\(:disabled\)\s*\{[^}]*\}/]
    expect(delete).to include("--color-error")
  end

  it "paints the Data page actions with the theme colour on hover" do
    # The archive, recycle bin and backup panels share one accent hover, so the
    # grey wash no longer shows up anywhere except the destructive buttons.
    %w[
      \.btn-trash-action:hover:not\(:disabled\)
      \.btn-backup-action:hover:not\(:disabled\)
      \.btn-archive-unarchive:hover:not\(:disabled\)
      \.page-tab:hover:not\(\.active\)
    ].each do |selector|
      block = styles[/#{selector}\s*\{[^}]*\}/]
      expect(block).to include("var(--color-accent-primary)"), "#{selector} should hover in the theme colour"
      expect(block).not_to include("--color-bg-hover"), "#{selector} should not fall back to the grey wash"
    end

    %w[
      \.btn-trash-danger:hover:not\(:disabled\)
      \.btn-trash-delete:hover:not\(:disabled\)
    ].each do |selector|
      expect(styles[/#{selector}[^{]*\{[^}]*\}/]).to include("--color-error")
    end
  end

  it "labels the 7-day cleanup in plain words" do
    expect(i18n).not_to include("清理 >7 天")
    expect(i18n).to include('"trash.emptyOld":    "清理 7 天前"')
  end
end
