# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "clacky/server/web_ui_controller"

RSpec.describe Clacky::Server::WebUIController, "#show_user_message" do
  let(:tmpdir) { Dir.mktmpdir("web_ui_controller_spec") }
  let(:events) { [] }
  let(:controller) do
    described_class.new("test-session", ->(_sid, event) { events << event })
  end

  after { FileUtils.rm_rf(tmpdir) }

  # Returns the images array of the emitted history_user_message event.
  def emitted_images(content, files)
    events.clear
    controller.show_user_message(content, files: files)
    ev = events.find { |e| e[:type] == "history_user_message" }
    ev ? ev[:images] : nil
  end

  it "passes data_url images through unchanged" do
    data_url = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
    images = emitted_images("hello", [{ name: "img.png", type: "image", data_url: data_url }])
    expect(images).to eq([data_url])
  end

  it "serves a disk image file (type image + existing path) via /api/local-image" do
    image_path = File.join(tmpdir, "puppy.png")
    File.binwrite(image_path, "PNGDATA")
    mtime_v = File.mtime(image_path).to_i

    images = emitted_images("", [{ name: "puppy.png", type: "image", path: image_path }])
    expect(images).to eq(["/api/local-image?path=#{CGI.escape(image_path)}&v=#{mtime_v}"])
  end

  it "falls back to pdf:name sentinel for disk files that are not images" do
    images = emitted_images("doc", [{ name: "report.pdf", type: "pdf", path: "/tmp/report.pdf" }])
    expect(images).to eq(["pdf:report.pdf"])
  end

  it "does not emit local-image URL when the image path does not exist on disk" do
    images = emitted_images("", [{ name: "gone.png", type: "image", path: "/tmp/definitely-missing.png" }])
    # Missing file -> falls through to name sentinel (badge), not a broken proxy URL
    expect(images).to eq(["pdf:gone.png"])
  end

  it "supports symbol and string keyed file hashes" do
    image_path = File.join(tmpdir, "str.png")
    File.binwrite(image_path, "PNG")
    images_str = emitted_images("", [{ "name" => "str.png", "type" => "image", "path" => image_path }])
    expect(images_str.first).to start_with("/api/local-image?path=")
  end

  it "omits images key entirely when no files are renderable" do
    events.clear
    controller.show_user_message("plain text", files: [])
    ev = events.find { |e| e[:type] == "history_user_message" }
    expect(ev.key?(:images)).to be(false)
  end
end
