# frozen_string_literal: true

RSpec.describe "Composer image attachment preview" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:app) { File.read(File.join(web_dir, "app.js")) }
  let(:sessions) { File.read(File.join(web_dir, "sessions.js")) }
  let(:new_session) { File.read(File.join(web_dir, "features/new-session/view.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }

  it "marks pending images in both composers as lightbox targets" do
    expect(sessions).to include('thumbnail.className = "img-preview-thumb"')
    expect(new_session).to include('thumbnail.className = "img-preview-thumb"')
  end

  it "routes sent and pending images through the shared lightbox" do
    expect(app).to include('const IMAGE_SELECTOR = ".msg-image-thumb, .img-preview-thumb"')
    expect(app).to include("e.target.matches(IMAGE_SELECTOR)")
    expect(styles).to include(".img-preview-thumb { cursor: zoom-in; }")
  end

  it "constructs the enlarged image without interpolating attachment data into HTML" do
    expect(app).to include('const image = document.createElement("img")')
    expect(app).to include("image.src = src")
    expect(app).to include('image.alt = alt || "image"')
    expect(app).not_to include('<img src="${src}"')
  end
end
