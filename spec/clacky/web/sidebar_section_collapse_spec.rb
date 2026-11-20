# frozen_string_literal: true

RSpec.describe "Sidebar section collapse" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:page)    { File.read(File.join(web_dir, "index.html")) }
  let(:css)     { File.read(File.join(web_dir, "app.css")) }
  let(:sidebar) { File.read(File.join(web_dir, "components/sidebar.js")) }

  %w[config data].each do |section|
    it "makes the #{section} section header fold its nav items" do
      expect(page).to include(%(data-collapsible-section="#{section}-nav-items"))
      expect(page).to match(/<div id="#{section}-nav-items" class="sidebar-section-body">/)
      expect(page).to match(/class="sidebar-section-chevron"/)
    end
  end

  it "binds the header clicks and persists the folded state" do
    expect(sidebar).to include("clacky-sidebar-collapsed-sections")
    expect(sidebar).to include('document.querySelectorAll("[data-collapsible-section]")')
    expect(sidebar).to include("localStorage.setItem(COLLAPSE_KEY")
    expect(sidebar).to include("_initSectionCollapse();")
  end

  it "hides the folded body and rotates its chevron" do
    expect(css).to include(".sidebar-section-body.is-collapsed {\n  display: none;\n}")
    expect(css).to include(".sidebar-section-header.is-collapsed .sidebar-section-chevron")
    expect(css).to include("transform: rotate(-90deg);")
  end
end
