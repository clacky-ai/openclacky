# frozen_string_literal: true

RSpec.describe "QQ QR bind modal UI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:view)   { File.read(File.join(web_dir, "features/channels/view.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }
  let(:i18n)   { File.read(File.join(web_dir, "i18n.js")) }

  it "embeds Tencent's official connect page inline instead of popping a new window" do
    expect(view).to include('id="qq-qr-frame" src="${_esc(task.connectUrl)}"')
    expect(view).not_to include("window.open")
    expect(styles).to include(".qq-qr-frame-wrap {")
  end

  it "keeps the open/copy fallback links" do
    expect(view).to include('id="qq-qr-open"')
    expect(view).to include('id="qq-qr-copy"')
  end

  it "keeps the success state open until the user dismisses it" do
    expect(view).not_to include("setTimeout(closeModal")
    expect(view).to include("if (e.target === overlay && bound) closeModal();")
    expect(view).to include('$("qq-qr-done").addEventListener("click", closeModal);')
  end

  it "blurs the expired QR and offers an in-place refresh" do
    expect(view).to include('$("qq-qr-frame-wrap").classList.add("expired");')
    expect(view).to include('$("qq-qr-frame").src = task.connectUrl;')
    expect(view).to include('onExpired("channels.qq.qr.sessionExpired")')
    expect(styles).to include(".qq-qr-frame-wrap.expired .qq-qr-frame")
    expect(styles).to include(".qq-qr-refresh {")
  end

  it "defines success copy in both languages and drops the old scan prompt" do
    %w[successDesc done expired sessionExpired].each do |key|
      expect(i18n.scan(%("channels.qq.qr.#{key}":)).size).to eq(2)
    end
    expect(i18n).not_to include("channels.qq.qr.scanPrompt")
  end
end
