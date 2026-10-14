# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "timeout"
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

RSpec.describe Clacky::Server::WebUIController, 'native feedback countdown' do
  let(:events) { [] }
  let(:started) { Queue.new }
  let(:controller) do
    described_class.new('s', lambda { |_sid, event|
      events << event
      started << event if event[:type] == 'feedback_countdown_started'
    })
  end
  let(:question) { { question: 'Pick?', recommended_label: 'Recommended' } }
  before do
    @now = 10.0
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { @now }
  end
  after do
    @worker&.kill
    @worker&.join
  end
  def start_wait
    @worker = Thread.new { controller.wait_for_feedback(timeout_seconds: 60, **question) {} }
    Timeout.timeout(1) { started.pop }
  end
  def advance(seconds)
    controller.instance_variable_get(:@mutex).synchronize do
      @now += seconds
      controller.instance_variable_get(:@pending_feedback)[:cond].signal
    end
  end
  it 'shows manual questions without creating a countdown' do
    shown = false
    expect(controller.wait_for_feedback(timeout_seconds: nil, **question) { shown = true }).to be_nil
    expect(shown).to be(true)
    expect(events).to be_empty
  end
  it 'uses the supplied timeout and recommended answer' do
    event = start_wait
    expect(event).to include(duration_seconds: 60, question: 'Pick?', recommended_label: 'Recommended')
    expect(event[:deadline_ms]).to be_within(100).of((Time.now.to_f * 1000).to_i + 60_000)
    advance(59)
    expect(controller.instance_variable_get(:@pending_feedback)[:answer]).to be_nil
    advance(1)
    expect(Timeout.timeout(1) { @worker.value.first }).to eq('Recommended')
    expect(events).to include(hash_including(type: 'feedback_countdown_resolved', resolution: 'timeout', answer: 'Recommended'))
  end
  it 'preserves caller-provided presentation, attachments and references' do
    start_wait
    options = { display_text: 'My answer', files: [{ path: '/tmp/answer.png' }], references_display: [{ name: 'previous chat' }] }
    expect(controller.deliver_feedback('Use this', **options)).to be(true)
    expect(Timeout.timeout(1) { @worker.value }).to eq(['Use this', options])
    expect(events).to include(hash_including(type: 'feedback_countdown_resolved', resolution: 'human'))
  end
  it 'replays the original deadline without restarting the wait' do
    event = start_wait
    advance(50)
    controller.replay_live_state
    expect(events.select { |e| e[:type] == 'feedback_countdown_started' }).to eq([event, event])
    advance(10)
    expect(Timeout.timeout(1) { @worker.value.first }).to eq('Recommended')
  end
  it 'cleans up cancellation with one generic cancelled outcome' do
    start_wait
    @worker.kill
    @worker.join
    expect(events).to include(hash_including(type: 'feedback_countdown_resolved', resolution: 'cancelled'))
    controller.replay_live_state
    expect(events.count { |e| e[:type] == 'feedback_countdown_started' }).to eq(1)
  end
  it 'rejects invalid timeouts without starting a wait' do
    [-1, 0.5, '60'].each do |timeout|
      expect { controller.wait_for_feedback(timeout_seconds: timeout, **question) {} }.to raise_error(ArgumentError)
    end
    expect(events).to be_empty
  end
end
