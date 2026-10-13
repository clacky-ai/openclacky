# frozen_string_literal: true

RSpec.describe "Session actions visibility" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }

  it "reveals actions on desktop interaction without reserving space for the active session" do
    desktop_styles = styles.split("@media (max-width: 768px)", 2).first

    expect(desktop_styles).to match(
      /\.session-item:hover \.session-actions-btn,\s*\.session-actions-btn:focus-visible \{.*?width: 1\.5rem;/m
    )
    expect(desktop_styles).not_to match(/\.session-item\.active \.session-actions-btn/)
  end

  it "keeps actions visible for the active session on mobile" do
    mobile_styles = styles.split("@media (max-width: 768px)", 2).last

    expect(mobile_styles).to match(
      /\.session-item\.active \.session-actions-btn \{.*?width: 1\.5rem;.*?opacity: 1;.*?pointer-events: auto;/m
    )
  end
end
