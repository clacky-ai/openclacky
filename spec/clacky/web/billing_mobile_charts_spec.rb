# frozen_string_literal: true

RSpec.describe "Billing mobile charts" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view) { File.read(File.join(web_dir, "features/billing/view.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }

  it "keeps the yearly heatmap cells readable in a horizontal scroller" do
    mobile_styles = styles.split("@media (max-width: 768px)", 2).last

    expect(mobile_styles).to match(/\.billing-heatmap-year \.billing-heat-year-wrap \{.*?overflow-x: auto;/m)
    expect(mobile_styles).to match(/\.billing-heat-dow-year \{.*?position: sticky;.*?left: 0;/m)
    expect(mobile_styles).to match(/\.billing-heat-week \{.*?flex: 0 0 13px;/m)
    expect(mobile_styles).to match(/\.billing-heat-week \.billing-heat-cell \{.*?max-width: none;.*?max-height: none;/m)
    expect(view).to include("_scrollHeatmapToLatest();")
    expect(view).to include("scroller.scrollLeft = scroller.scrollWidth;")
  end

  it "snaps mobile heatmap taps to the nearest cell and marks the selection" do
    expect(view).to include('grid.addEventListener("click"')
    expect(view).to include("_nearestHeatmapCell(grid, e.clientX, e.clientY)")
    expect(view).to include('cell.classList.add("is-active")')
  end

  it "uses a taller mobile trend chart with readable labels and points" do
    mobile_styles = styles.split("@media (max-width: 768px)", 2).last

    expect(view).to include("const h = mobileLayout ? 160 : 100;")
    expect(view).to include("const dotRadius = mobileLayout ? 4 : 3;")
    expect(mobile_styles).to match(/\.billing-trend-chart \{.*?min-height: 10rem;/m)
    expect(mobile_styles).to match(/\.billing-trend-y-label,\s*\.billing-trend-x-label \{.*?font-size: 10px;/m)
    expect(mobile_styles).to match(/\.billing-trend-dot \{.*?opacity: 1;/m)
  end

  it "supports touch inspection and redraws only when crossing the mobile breakpoint" do
    expect(view).to include('svg.addEventListener("pointerdown"')
    expect(view).to include('window.matchMedia?.(MOBILE_CHART_MEDIA_QUERY).addEventListener?.("change", _render);')
  end
end
