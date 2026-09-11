# frozen_string_literal: true
require "spec_helper"
require "clacky/cli_guidance"
require "clacky/ui2/components/input_area"
require "clacky/rich_ui"

RSpec.describe Clacky::CliGuidance do
  let(:ui) do
    Class.new do
      include Clacky::CliGuidance
      attr_accessor :queue_input_while_running
    end.new
  end
  let(:entry) { { id: "a", content: "Keep the backend unchanged", options: { files: [{ name: "spec.md" }] } } }

  it "keeps pending content until cleared without adding sessionbar state" do
    expect(ui.guidance_lines).to eq([])
    ui.show_input_queue([entry])
    expect(ui.guidance_lines).to eq(["Pending · Ctrl+D delete last · Ctrl+G send now", "  · Keep the backend unchanged"])
    expect(ui).not_to respond_to(:guidance_status)
    ui.show_input_queue([])
    expect(ui.guidance_lines).to eq([])
  end

  it "defers running guidance and does not introduce pending management commands" do
    ui.queue_input_while_running = -> { false }
    expect(ui.guidance_control?("/pending")).to be(false)
    expect(ui.guidance_deferred?("normal message")).to be(false)
    ui.queue_input_while_running = -> { true }
    expect(ui.guidance_deferred?("supplement")).to be(true)
  end

  it "bounds the fixed area and flattens multiline content" do
    ui.show_input_queue(5.times.map { entry.merge(content: "first\nsecond") })
    expect(ui.guidance_lines.length).to eq(5)
    expect(ui.guidance_lines.last).to eq("  · first second")
    expect(ui.guidance_lines[1]).to eq("  … 2 earlier")
  end

  it "shows filenames for attachment-only guidance" do
    ui.show_input_queue([entry.merge(content: "")])
    expect(ui.guidance_lines.last).to include("spec.md")
  end

  it "grows and shrinks UI2 input height while preserving its sessionbar" do
    area = Clacky::UI2::Components::InputArea.new
    area.guidance_lines_provider = -> { ui.guidance_lines }
    base_height = area.required_height
    bar = area.send(:build_sessionbar_content)
    ui.show_input_queue([entry])
    expect(area.required_height).to eq(base_height + 2)
    expect(area.send(:build_sessionbar_content)).to eq(bar)
    ui.show_input_queue([])
    expect(area.required_height).to eq(base_height)
  end

  it "renders pending guidance inside the Rich composer without a separate layout region" do
    rich = Clacky::RichUIController.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test")
    expect(rich.shell).not_to receive(:add_user_message)
    rich.shell.composer.insert_text("draft")
    rich.shell.layout.calculate_dimensions(100, 30)
    rich.shell.layout.render
    base_height = rich.shell.composer.desired_height
    base_cursor = rich.shell.composer.native_cursor_position
    rich.show_input_queue([entry])
    rich.shell.layout.calculate_dimensions(100, 30)
    rich.shell.layout.render
    expect(rich.shell.layout[:pending_guidance]).to be_nil
    expect(rich.shell.composer.render.join).to include("Keep the backend unchanged", "draft")
    expect(rich.shell.composer.desired_height).to eq(base_height + 2)
    cursor = rich.shell.composer.native_cursor_position
    expect(cursor).not_to be_nil
    expect(cursor[0]).to eq(base_cursor[0] + 2)
    rich.show_input_queue([])
    expect(rich.shell.composer.desired_height).to eq(base_height)
  end

  it "prints accepted guidance as a user message, not an info notice" do
    rich = Clacky::RichUIController.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test")
    expect(rich).not_to receive(:show_info)
    expect(rich.shell).to receive(:add_user_message).with("accepted")
    rich.show_user_message("accepted", steering: true)
  end
  it "targets the last displayed ID without changing the input callback" do
    calls = []
    ui.on_guidance_action { |action, id| calls << [action, id] }
    ui.show_input_queue([entry, entry.merge(id: "last")])
    expect(ui.request_guidance_action(:send_now)).to be(true)
    expect(calls).to eq([[:send_now, "last"]])
    ui.show_input_queue([])
    expect(ui.request_guidance_action(:remove)).to be(false)
  end

  it "routes Rich Ctrl+D and Ctrl+G without modifying the composer draft" do
    rich = Clacky::RichUIController.new(working_dir: Dir.pwd, mode: "confirm_safes", model: "test")
    allow(rich).to receive(:run_callback_async) { |&block| block.call }
    rich.shell.composer.insert_text("unfinished draft")
    rich.show_input_queue([entry])
    actions = []
    rich.on_guidance_action { |action, id| actions << [action, id] }
    rich.shell.composer.send(:ctrl_d, nil)
    expect(actions.last).to eq([:remove, "a"])
    rich.shell.layout.notify_listeners(name: :ctrl_g, type: :key)
    expect(actions.last).to eq([:send_now, "a"])
    expect(rich.shell.composer.value).to eq("unfinished draft")
  end

  it "decodes Ctrl+G in UI2" do
    screen = Clacky::UI2::ScreenBuffer.allocate
    screen.instance_variable_set(:@rapid_input_threshold, 0.01)
    allow(screen).to receive(:read_char).and_return("\u0007")
    expect(screen.read_key).to eq(:ctrl_g)
  end

end
