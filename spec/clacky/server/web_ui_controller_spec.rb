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

  it "passes skill_command_display through to the history_user_message event" do
    events.clear
    controller.show_user_message("/pptx", skill_command: "pptx", skill_command_display: "幻灯片制作")
    ev = events.find { |e| e[:type] == "history_user_message" }
    expect(ev[:skill_command]).to eq("pptx")
    expect(ev[:skill_command_display]).to eq("幻灯片制作")
  end

  it "omits skill_command_display when absent" do
    events.clear
    controller.show_user_message("hello")
    ev = events.find { |e| e[:type] == "history_user_message" }
    expect(ev.key?(:skill_command_display)).to be(false)
  end

  it "passes references through so live bubbles can render mention badges" do
    events.clear
    refs = [{ "type" => "file", "name" => "app.rb", "path" => "/tmp/app.rb" }]
    controller.show_user_message("check this", references: refs)
    ev = events.find { |e| e[:type] == "history_user_message" }
    expect(ev[:references]).to eq(refs)
  end

  it "omits references when none are given" do
    events.clear
    controller.show_user_message("hello")
    ev = events.find { |e| e[:type] == "history_user_message" }
    expect(ev.key?(:references)).to be(false)
  end
end

RSpec.describe Clacky::Server::WebUIController, "#show_complete" do
  let(:events) { [] }
  let(:controller) do
    described_class.new("test-session", ->(_sid, event) { events << event })
  end

  it "emits an optional completed task id" do
    controller.show_complete(iterations: 3, cost: 0.12, task_id: 6)
    expect(events.last).to include(type: "complete", session_id: "test-session", task_id: 6)

    controller.show_complete(iterations: 1, cost: 0.01)
    expect(events.last).not_to have_key(:task_id)
  end
end

RSpec.describe Clacky::Server::WebUIController, "#show_assistant_message" do
  let(:events) { [] }
  let(:controller) do
    described_class.new("test-session", ->(_sid, event) { events << event })
  end
  let(:subscriber) { double("channel_ui") }

  before { controller.subscribe_channel(subscriber) }

  it "keeps visualization references on Web while stripping them at the channel boundary" do
    reference = "visualize{\"artifact_id\":\"#{"a" * 64}\",\"title\":\"Demo\"}"
    expect(subscriber).to receive(:show_assistant_message)
      .with("Summary", files: [], interim: false)

    controller.show_assistant_message("Summary\n\n#{reference}", files: [])

    expect(events.last[:content]).to include(reference)
  end
end

RSpec.describe Clacky::Server::WebUIController, "#output_capabilities" do
  let(:controller) do
    described_class.new("test-session", ->(_sid, _event) {})
  end

  it "supports artifacts for a Web-only session" do
    expect(controller.output_capabilities).to eq([:artifact])
  end

  it "keeps configured capabilities separate from subscriber intersections" do
    controller = described_class.new("session-1", ->(_session_id, _event) {})
    unsupported = double("unsupported_channel", output_capabilities: [])

    controller.subscribe_channel(unsupported)

    expect(controller.output_capabilities).to eq([])
    expect(controller.configured_output_capabilities).to eq([:artifact])
  end

  it "returns only capabilities supported by every channel subscriber" do
    supported = double("supported_channel", output_capabilities: [:artifact])
    unsupported = double("unsupported_channel", output_capabilities: [])

    controller.subscribe_channel(supported)
    expect(controller.output_capabilities).to eq([:artifact])

    controller.subscribe_channel(unsupported)
    expect(controller.output_capabilities).to eq([])

    controller.unsubscribe_channel(unsupported)
    expect(controller.output_capabilities).to eq([:artifact])
  end

  it "can disable artifact output for non-interactive server sessions" do
    controller = described_class.new(
      "test-session",
      ->(_sid, _event) {},
      output_capabilities: []
    )

    expect(controller.output_capabilities).to eq([])
  end

  it "keeps a legacy output contract unknown until a task surface resolves it" do
    controller = described_class.new(
      "test-session",
      ->(_sid, _event) {},
      output_capabilities: nil
    )

    expect(controller.output_capabilities_configured?).to be(false)
    expect(controller.configured_output_capabilities).to be_nil
    expect(controller.output_capabilities).to eq([])

    expect(controller.resolve_output_capabilities!([:artifact])).to eq([:artifact])
    expect(controller.output_capabilities_configured?).to be(true)
    expect(controller.configured_output_capabilities).to eq([:artifact])
  end

  it "does not overwrite an explicit empty output contract" do
    controller = described_class.new(
      "test-session",
      ->(_sid, _event) {},
      output_capabilities: []
    )

    expect(controller.resolve_output_capabilities!([:artifact])).to eq([])
    expect(controller.configured_output_capabilities).to eq([])
  end

  it "resolves a legacy channel-bound session to the subscriber intersection" do
    controller = described_class.new(
      "test-session",
      ->(_sid, _event) {},
      output_capabilities: nil
    )
    controller.subscribe_channel(double("channel", output_capabilities: []))

    expect(controller.resolve_output_capabilities!([:artifact])).to eq([])
    expect(controller.configured_output_capabilities).to eq([])
  end
end

RSpec.describe Clacky::Server::WebUIController, "#show_tool_call" do
  let(:events) { [] }
  let(:controller) do
    described_class.new("test-session", ->(_sid, event) { events << event })
  end
  let(:subscriber) { double("channel_ui", show_tool_call: nil) }
  let(:ask_args) { { "questions" => [{ "question" => "Pick one?", "options" => %w[a b] }] } }

  before { controller.subscribe_channel(subscriber) }

  it "forwards ask_user to channel subscribers so IM can render it as text" do
    expect(subscriber).to receive(:show_tool_call).with("ask_user", ask_args)
    controller.show_tool_call("ask_user", ask_args)
  end

  it "still emits the browser feedback card" do
    controller.show_tool_call("ask_user", ask_args)
    ev = events.find { |e| e[:type] == "request_feedback" }
    expect(ev[:question]).to eq("Pick one?")
    expect(ev[:options]).to eq(%w[a b])
  end
end
