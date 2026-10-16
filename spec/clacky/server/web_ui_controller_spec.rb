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

RSpec.describe Clacky::Server::WebUIController, "feedback countdown" do
  let(:events) { Queue.new }
  let(:controller) { described_class.new("s", ->(_sid, event) { events << event }) }

  def next_event
    Timeout.timeout(2) { events.pop }
  end

  after { @worker&.kill; @worker&.join }

  it "times out without selecting a recommended answer" do
    expect(controller.request_feedback_with_countdown(seconds: 0)).to eq(:timeout)
    expect(next_event[:deadline_ms]).to be_a(Integer)
    expect(next_event).to include(resolved: true, resolution: :timeout)
  end

  it "ends countdown waiting on intervention and rejects stale interventions" do
    @worker = Thread.new { controller.request_feedback_with_countdown(seconds: 20) }
    started = next_event
    expect(controller.intervene_feedback("stale-id")).to be false
    expect(controller.intervene_feedback(started[:request_id])).to be true
    expect(next_event[:deadline_ms]).to be_nil
    expect(@worker.join(2).value).to eq(:intervened)
    expect(next_event).to include(resolved: true, resolution: :intervened)
    expect(controller.intervene_feedback(started[:request_id])).to be false
    controller.replay_live_state
    expect(next_event).to include(resolved: true)
  end

  it "pauses a running countdown in manual mode and restarts it in auto mode" do
    @worker = Thread.new { controller.request_feedback_with_countdown(seconds: 0.08) }
    started = next_event
    controller.update_permission_mode(:confirm_all)
    expect(next_event).to include(request_id: started[:request_id], deadline_ms: nil)
    sleep 0.1
    expect(@worker).to be_alive
    controller.replay_live_state
    expect(next_event[:deadline_ms]).to be_nil
    controller.update_permission_mode(:auto_approve)
    expect(next_event[:deadline_ms]).to be > started[:deadline_ms]
    expect(@worker.join(2).value).to eq(:timeout)
  end

  it "does not restart an intervened countdown when switching back to auto" do
    @worker = Thread.new { controller.request_feedback_with_countdown(seconds: 20) }
    started = next_event
    controller.intervene_feedback(started[:request_id])
    expect(@worker.join(2).value).to eq(:intervened)
    controller.update_permission_mode(:confirm_all)
    controller.update_permission_mode(:auto_approve)
    controller.replay_live_state
    next_event
    expect(next_event).to include(resolved: true, resolution: :intervened)
    expect(next_event).to include(resolved: true)
  end

  it "honors a switch to manual immediately before the countdown starts" do
    controller.update_permission_mode(:confirm_all)
    @worker = Thread.new { controller.request_feedback_with_countdown(seconds: 0) }
    started = next_event
    expect(started[:deadline_ms]).to be_nil
    controller.intervene_feedback(started[:request_id])
    expect(@worker.join(2).value).to eq(:intervened)
  end

  it "replays the original deadline and cleans up on interruption" do
    @worker = Thread.new do
      controller.request_feedback_with_countdown(seconds: 20)
    rescue Clacky::AgentInterrupted
      :interrupted
    end
    started = next_event
    controller.replay_live_state
    expect(next_event).to include(request_id: started[:request_id], deadline_ms: started[:deadline_ms])
    @worker.raise(Clacky::AgentInterrupted)
    expect(@worker.join(2).value).to eq(:interrupted)
    expect(next_event).to include(resolved: true, resolution: :cancelled)
    controller.replay_live_state
    expect(next_event).to include(resolved: true)
  end
end
