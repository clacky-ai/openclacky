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

  def emitted_event(content, files)
    events.clear
    controller.show_user_message(content, files: files)
    events.find { |e| e[:type] == "history_user_message" }
  end

  # Returns the images array of the emitted history_user_message event.
  def emitted_images(content, files)
    emitted_event(content, files)&.dig(:images)
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

  it "emits a path-backed attachment for a disk file that still exists" do
    file_path = File.join(tmpdir, "report.pdf")
    File.binwrite(file_path, "PDF")

    event = emitted_event("doc", [{ name: "report.pdf", type: "pdf", path: file_path }])
    expect(event[:attachments]).to eq([{ name: "report.pdf", type: "pdf", path: file_path }])
    expect(event).not_to have_key(:images)
  end

  it "keeps a missing disk attachment visible without an actionable path" do
    event = emitted_event("doc", [{ name: "gone.pdf", type: "pdf", path: "/tmp/definitely-missing.pdf" }])
    expect(event[:attachments]).to eq([{ name: "gone.pdf", type: "pdf" }])
  end

  it "does not turn @ references into attachment cards" do
    event = emitted_event("doc", [{ name: "app.rb", path: "/tmp/app.rb", reference: true }])
    expect(event).not_to have_key(:attachments)
    expect(event).not_to have_key(:images)
  end

  it "does not emit local-image URL when the image path does not exist on disk" do
    images = emitted_images("", [{ name: "gone.png", type: "image", path: "/tmp/definitely-missing.png" }])
    expect(images).to eq(["expired:gone.png"])
  end

  it "recognizes live image attachments by mime_type" do
    image_path = File.join(tmpdir, "live.png")
    File.binwrite(image_path, "PNG")

    images = emitted_images("", [{ name: "live.png", mime_type: "image/png", path: image_path }])
    expect(images.first).to start_with("/api/local-image?path=")
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

  it "ends a running countdown as an intervention when switching to manual mode" do
    @worker = Thread.new { controller.request_feedback_with_countdown(seconds: 20) }
    started = next_event
    controller.update_permission_mode(:confirm_all)
    expect(@worker.join(2).value).to eq(:intervened)
    expect(next_event).to include(request_id: started[:request_id], resolved: true, resolution: :intervened)
    controller.replay_live_state
    expect(next_event).to include(resolved: true)
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

  it "skips the countdown when manual mode is already active" do
    controller.update_permission_mode(:confirm_all)
    expect(controller.request_feedback_with_countdown(seconds: 0)).to eq(:intervened)
    expect(events).to be_empty
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

RSpec.describe Clacky::Server::WebUIController, "streamed assistant reply" do
  let(:events) { [] }
  let(:controller) { described_class.new("test-session", ->(_sid, event) { events << event }) }

  def of_type(type)
    events.select { |e| e[:type] == type }
  end

  it "emits each fragment with the UTF-8 byte offset it starts at, per kind" do
    controller.stream_assistant_delta(:reasoning, "plan")
    controller.stream_assistant_delta(:text, "Hel")
    controller.stream_assistant_delta(:text, "lo")
    controller.stream_assistant_delta(:text, "👍")
    controller.stream_assistant_delta(:text, "!")

    expect(of_type("assistant_delta").map { |e| [e[:kind], e[:delta], e[:offset]] })
      .to eq([
        ["reasoning", "plan", 0],
        ["text", "Hel", 0],
        ["text", "lo", 3],
        ["text", "👍", 5],
        ["text", "!", 9]
      ])
    expect(of_type("assistant_delta").map { |e| e[:stream_id] }.uniq.size).to eq(1)
  end

  it "tags the final assistant_message with the stream it supersedes" do
    controller.stream_assistant_delta(:reasoning, "think")
    stream_id = of_type("assistant_delta").first[:stream_id]

    controller.show_assistant_message("<think>\nthink\n</think>\nDone", files: [])
    controller.show_assistant_message("Next", files: [])

    messages = of_type("assistant_message")
    expect(messages.first[:stream_id]).to eq(stream_id)
    expect(messages.last).not_to have_key(:stream_id)
  end

  it "discards an open stream once and starts a fresh id afterwards" do
    controller.stream_assistant_delta(:text, "draft")
    first_id = of_type("assistant_delta").first[:stream_id]

    controller.discard_assistant_stream
    controller.discard_assistant_stream
    controller.stream_assistant_delta(:text, "retry")

    expect(of_type("assistant_stream_discard").map { |e| e[:stream_id] }).to eq([first_id])
    expect(of_type("assistant_delta").last).to include(offset: 0)
    expect(of_type("assistant_delta").last[:stream_id]).not_to eq(first_id)
  end

  it "replays the live reply as offset-0 snapshots" do
    controller.show_progress("Thinking")
    controller.stream_assistant_delta(:reasoning, "plan")
    controller.stream_assistant_delta(:text, "Hi")
    controller.stream_assistant_delta(:text, " there")
    events.clear

    controller.replay_live_state

    expect(of_type("assistant_delta").map { |e| [e[:kind], e[:delta], e[:offset], e[:snapshot]] })
      .to eq([["reasoning", "plan", 0, true], ["text", "Hi there", 0, true]])
  end

  it "reports a tool call being written by name and absolute argument size only" do
    controller.stream_assistant_delta(:tool_input, "{}")
    controller.stream_assistant_delta(:tool_start, "write")
    controller.stream_assistant_delta(:tool_input, '{"content":"')
    controller.stream_assistant_delta(:tool_input, "👍")
    controller.stream_assistant_delta(:tool_start, "shell")

    progress = of_type("assistant_tool_progress")
    expect(progress.map { |e| e.slice(:index, :name, :bytes) }).to eq([
      { index: 0, name: "write", bytes: 0 },
      { index: 0, name: "write", bytes: 12 },
      { index: 0, name: "write", bytes: 16 },
      { index: 1, name: "shell", bytes: 0 }
    ])
    expect(progress.none? { |e| e.key?(:delta) }).to be(true)
    expect(of_type("assistant_delta")).to be_empty
  end

  it "drops pending tool calls with the stream and replays live ones" do
    controller.show_progress("Thinking")
    controller.stream_assistant_delta(:text, "Let me check")
    controller.stream_assistant_delta(:tool_start, "read")
    controller.stream_assistant_delta(:tool_input, '{"path":"a"}')
    stream_id = of_type("assistant_delta").first[:stream_id]
    events.clear

    controller.replay_live_state

    expect(of_type("assistant_tool_progress"))
      .to eq([{ type: "assistant_tool_progress", session_id: "test-session",
                stream_id: stream_id, index: 0, name: "read", bytes: 12 }])

    controller.show_assistant_message("Let me check", files: [])
    events.clear
    controller.replay_live_state
    expect(of_type("assistant_tool_progress")).to be_empty
  end

  it "does not replay a stream once progress has ended" do
    controller.stream_assistant_delta(:text, "Hi")
    events.clear

    controller.replay_live_state

    expect(of_type("assistant_delta")).to be_empty
  end

  it "keeps concurrent phases on separate streams" do
    threads = %w[phase-a phase-b].map do |phase|
      Thread.new do
        Thread.current[:clacky_phase_id] = phase
        3.times { |i| controller.stream_assistant_delta(:text, "#{phase}-#{i} ") }
      end
    end
    threads.each(&:join)

    by_phase = of_type("assistant_delta").group_by { |e| e[:phase_id] }
    expect(by_phase.keys).to contain_exactly("phase-a", "phase-b")
    expect(by_phase["phase-a"].map { |e| e[:stream_id] }.uniq.size).to eq(1)
    expect(by_phase["phase-b"].map { |e| e[:stream_id] }.uniq.size).to eq(1)
    expect(by_phase["phase-a"].first[:stream_id]).not_to eq(by_phase["phase-b"].first[:stream_id])
    expect(by_phase["phase-a"].map { |e| e[:delta] }.join).to eq("phase-a-0 phase-a-1 phase-a-2 ")
    expect(by_phase["phase-b"].map { |e| e[:delta] }.join).to eq("phase-b-0 phase-b-1 phase-b-2 ")
    expect(by_phase["phase-a"].map { |e| e[:offset] }).to eq([0, "phase-a-0 ".bytesize, ("phase-a-0 phase-a-1 ").bytesize])

    Thread.current[:clacky_phase_id] = "phase-a"
    controller.phase_end("phase-a")
    expect(of_type("assistant_stream_discard").map { |e| e[:stream_id] })
      .to eq([by_phase["phase-a"].first[:stream_id]])

    Thread.current[:clacky_phase_id] = "phase-a"
    controller.discard_assistant_stream
    expect(of_type("assistant_stream_discard").map { |e| e[:stream_id] })
      .to eq([by_phase["phase-a"].first[:stream_id]])

    controller.show_progress("Thinking")
    events.clear
    controller.replay_live_state
    expect(of_type("assistant_delta").map { |e| e[:stream_id] }.uniq)
      .to eq([by_phase["phase-b"].first[:stream_id]])
  ensure
    Thread.current[:clacky_phase_id] = nil
  end
end
