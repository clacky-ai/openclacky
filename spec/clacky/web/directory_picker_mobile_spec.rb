# frozen_string_literal: true

RSpec.describe "Directory picker mobile layout" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:sessions) { File.read(File.join(web_dir, "sessions.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }

  it "adds a picker-specific overlay and mobile close header" do
    expect(sessions).to include('overlay.className = "modal-overlay dp-overlay";')
    expect(sessions).to include('mobileHeader.className = "dp-mobile-header";')
    expect(sessions).to include(
      'mobileTitle.textContent = t("sessions.modal.dirpicker.title", "Select Working Directory");'
    )
    expect(sessions).to include('mobileCloseButton.addEventListener("click", cancelPicker);')
  end

  it "enters folders on a single tap in the mobile layout" do
    expect(sessions).to include(
      'const mobileLayout = window.matchMedia("(max-width: 768px)");'
    )
    expect(sessions).to match(
      /row\.addEventListener\("click".*?if \(mobileLayout\.matches\) \{\s*navigateTo\(entry\.absPath, true\);\s*return;/m
    )
    expect(sessions).to match(
      /row\.addEventListener\("dblclick".*?if \(mobileLayout\.matches\) return;.*?navigateTo\(entry\.absPath, true\);/m
    )
  end

  it "uses a full-screen picker and horizontal places list at the mobile breakpoint" do
    mobile_styles = styles.split("@media (max-width: 768px)", 2).last

    expect(mobile_styles).to match(/\.dp-overlay \{.*?padding: 0;/m)
    expect(mobile_styles).to match(/\.dp-modal \{.*?height: 100dvh;.*?flex-direction: column;/m)
    expect(mobile_styles).to match(/\.dp-sidebar \{.*?overflow-x: auto;.*?overflow-y: hidden;/m)
    expect(mobile_styles).to match(/\.dp-footer-actions,\s*\.dp-newfolder-btn \{.*?white-space: nowrap;/m)
  end

  it "keeps the mobile header hidden in the desktop layout" do
    desktop_styles = styles.split("@media (max-width: 768px)", 2).first

    expect(desktop_styles).to match(/\.dp-mobile-header \{\s*display: none;/m)
  end
end
