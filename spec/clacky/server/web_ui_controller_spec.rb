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

RSpec.describe Clacky::Server::WebUIController, "#show_token_usage" do
  it "keeps the browser event type authoritative" do
    events = []
    controller = described_class.new(
      "test-session", ->(_sid, event) { events << event }
    )

    controller.show_token_usage(type: :usage, used: 10, size: 100)

    expect(events.last).to eq(
      type: "token_usage", session_id: "test-session", used: 10, size: 100
    )
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

RSpec.describe Clacky::Server::WebUIController, "runtime event metadata" do
  let(:events) { [] }
  let(:controller) do
    described_class.new("test-session", ->(_sid, event) { events << event })
  end

  it "emits keyed assistant deltas and finalizes the same browser stream" do
    controller.show_assistant_delta("assistant-1", "Hello ")
    controller.show_assistant_delta("assistant-2", "world")
    controller.finish_assistant_stream(
      "assistant-1",
      "Hello world",
      files: [],
      created_at: 12.5,
      message_ids: %w[assistant-1 assistant-2]
    )

    expect(events).to eq([
      {
        type: "assistant_message", session_id: "test-session",
        message_id: "assistant-1", content: "Hello ", files: [],
        interim: true, delta: true
      },
      {
        type: "assistant_message", session_id: "test-session",
        message_id: "assistant-2", content: "world", files: [],
        interim: true, delta: true
      },
      {
        type: "assistant_message", session_id: "test-session",
        message_id: "assistant-1", content: "Hello world", files: [],
        message_ids: %w[assistant-1 assistant-2], created_at: 12.5,
        interim: false, delta: false
      }
    ])
  end

  it "keeps tool call ids on browser call and result events" do
    controller.show_keyed_tool_call(
      "terminal", { "command" => "pwd" }, tool_call_id: "tool-1"
    )
    controller.show_keyed_tool_result(
      "command failed",
      tool_call_id: "tool-1",
      status: "failed",
      exit_code: 2
    )

    expect(events[0]).to include(
      type: "tool_call", tool_call_id: "tool-1", name: "terminal"
    )
    expect(events[1]).to include(
      type: "tool_result", tool_call_id: "tool-1", result: "command failed",
      status: "failed", exit_code: 2
    )
  end
end

RSpec.describe Clacky::Server::WebUIController, "#cancel_pending_confirmations" do
  it "unblocks every permission waiter with the supplied safe default" do
    emitted = Queue.new
    result = Queue.new
    controller = described_class.new(
      "test-session", ->(_sid, event) { emitted << event }
    )
    waiter = Thread.new do
      result << controller.request_confirmation("Allow action?", default: true)
    end
    expect(emitted.pop).to include(type: "request_confirmation")

    expect(controller.cancel_pending_confirmations(result: false)).to eq(1)

    expect(result.pop).to be(false)
    expect(waiter.join(1)).not_to be_nil
  ensure
    waiter&.kill if waiter&.alive?
  end


  it "does not lose an answer delivered synchronously while emitting the prompt" do
    controller = nil
    controller = described_class.new(
      "test-session",
      lambda do |_sid, event|
        controller.deliver_confirmation(event[:id], true)
      end
    )

    answer = Timeout.timeout(0.2) do
      controller.request_confirmation("Allow action?", default: false)
    end

    expect(answer).to be(true)
  end
end
