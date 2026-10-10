# frozen_string_literal: true

RSpec.describe "Session title overflow" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:sessions) { File.read(File.join(web_dir, "sessions.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }

  it "uses a separately moving title layer without moving badges" do
    expect(sessions).to include(
      '<span class="session-name__text"><span class="session-name__content">${nameHtml}</span></span>${badgeHtml}'
    )
    expect(sessions).to include('content.scrollWidth - viewport.clientWidth')
    expect(sessions).to include('item.classList.add("session-name-scrolling")')
  end

  it "fades clipped titles and scrolls only while hovered" do
    expect(styles).to match(/\.session-item:not\(\.group-item\).*?\.session-name__text \{.*?mask-image:/m)
    expect(styles).to match(/\.session-item\.session-name-scrolling \.session-name__content \{.*?translateX/m)
    expect(styles).to match(/prefers-reduced-motion: reduce.*?\.session-name__content/m)
  end
end
