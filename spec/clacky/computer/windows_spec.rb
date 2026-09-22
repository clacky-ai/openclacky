# frozen_string_literal: true

require "spec_helper"
require File.expand_path(
  "../../../lib/clacky/default_extensions/computer-use/lib/computer/windows", __dir__
)

RSpec.describe Clacky::Computer::Windows do
  # The real constants point at /mnt/c, which does not exist on a macOS build
  # host — which is exactly right, since the code under test is the path mapping.
  let(:shared_dir) { Clacky::Computer::Windows::SHARED_WSL_DIR }
  let(:shots_dir) { Clacky::Computer::Windows::SHOTS_WSL_DIR }

  subject(:backend) { described_class.new }

  before do
    allow(backend).to receive(:ensure_agent!)
    allow(FileUtils).to receive(:mkdir_p)
  end

  def stub_reply(json, exitstatus: 0)
    allow(Open3).to receive(:capture3)
      .and_return([json, "", instance_double(Process::Status, exitstatus: exitstatus)])
  end

  def stub_agent(payload)
    allow(backend).to receive(:run).and_return(payload)
  end

  describe ".wsl?" do
    it "is false on macOS" do
      stub_const("RUBY_PLATFORM", "arm64-darwin24")

      expect(described_class.wsl?).to be false
    end

    it "is false on Linux without a mounted Windows drive" do
      stub_const("RUBY_PLATFORM", "x86_64-linux")
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with("/proc/version").and_return("Linux version 6.5.0-generic")
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/mnt/c/Windows").and_return(false)

      expect(described_class.wsl?).to be false
    end

    it "is true on WSL" do
      stub_const("RUBY_PLATFORM", "aarch64-linux")
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with("/proc/version")
                                       .and_return("Linux version 6.6.87.2-microsoft-standard-WSL2")
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/mnt/c/Windows").and_return(true)

      expect(described_class.wsl?).to be true
    end
  end

  describe "#displays" do
    it "normalizes a lone screen, which PowerShell serializes as an object" do
      stub_agent("ok" => true, "screens" => {
                   "id" => 0, "primary" => true, "x" => 0, "y" => 0, "width" => 1512, "height" => 949
                 })

      displays = backend.displays

      expect(displays.length).to eq(1)
      expect(displays.first.width).to eq(1512)
      expect(displays.first.height).to eq(949)
      expect(displays.first.main).to be true
      expect(displays.first.origin_known).to be true
    end

    it "keeps every screen when several are attached" do
      stub_agent("ok" => true, "screens" => [
                   { "id" => 0, "primary" => true, "x" => 0, "y" => 0, "width" => 1512, "height" => 949 },
                   { "id" => 1, "primary" => false, "x" => 1512, "y" => 0, "width" => 1920, "height" => 1080 }
                 ])

      displays = backend.displays

      expect(displays.map(&:id)).to eq([0, 1])
      expect(displays.last.origin_x).to eq(1512)
      expect(displays.last.main).to be false
    end

    it "asks the agent only once" do
      expect(backend).to receive(:run).once.and_return("ok" => true, "screens" => [])

      2.times { backend.displays }
    end
  end

  describe "#capture" do
    let(:capture_reply) do
      {
        "ok" => true, "origin_x" => 0, "origin_y" => 0,
        "points_width" => 1512, "points_height" => 949,
        "image_width" => 1512, "image_height" => 949,
        "model_path" => "C:\\Users\\Public\\clacky-computer\\shots\\shot-1.png"
      }
    end

    it "sends a Windows path and the display rect" do
      sent = nil
      allow(backend).to receive(:run) { |_command, params| sent = params; capture_reply }
      display = Clacky::Computer::Geometry::Display.new(0, 0, 0, 1512, 949, 1512, 949, true, false, true)

      capture = backend.capture(path: File.join(shots_dir, "shot-1.png"), display: display)

      expect(sent[:path]).to eq("C:\\Users\\Public\\clacky-computer\\shots\\shot-1.png")
      expect(sent[:width]).to eq(1512)
      expect(sent[:height]).to eq(949)
      expect(capture.model_path).to eq(File.join(shots_dir, "shot-1.png"))
      expect(capture.points_per_image_pixel_x).to eq(1.0)
    end

    it "lets the agent choose the desktop when there is no rect" do
      sent = nil
      allow(backend).to receive(:run) { |_command, params| sent = params; capture_reply }

      backend.capture(path: File.join(shots_dir, "shot-1.png"))

      expect(sent).not_to have_key(:x)
      expect(sent).not_to have_key(:width)
    end

    it "relocates a capture that would land inside the WSL filesystem" do
      sent = nil
      allow(backend).to receive(:run) { |_command, params| sent = params; capture_reply }

      capture = backend.capture(path: "/tmp/whatever/shot-9.png")

      expect(sent[:path]).to eq("C:\\Users\\Public\\clacky-computer\\shots\\shot-9.png")
      expect(capture.path).to eq(File.join(shots_dir, "shot-9.png"))
    end

    it "passes the downscale and grid options through" do
      sent = nil
      allow(backend).to receive(:run) { |_command, params| sent = params; capture_reply }

      backend.capture(path: File.join(shots_dir, "shot-1.png"), max_width: 800, grid_step: 200)

      expect(sent[:max_width]).to eq(800)
      expect(sent[:grid_step]).to eq(200)
    end

    it "omits a zero max_width so the agent keeps the full resolution" do
      sent = nil
      allow(backend).to receive(:run) { |_command, params| sent = params; capture_reply }

      backend.capture(path: File.join(shots_dir, "shot-1.png"), max_width: 0)

      expect(sent).not_to have_key(:max_width)
    end
  end

  describe "#run" do
    it "parses the JSON the agent prints" do
      stub_reply('{"ok":true,"session_id":1}')

      expect(backend.run("info")).to include("ok" => true, "session_id" => 1)
    end

    it "ignores PowerShell noise printed before the JSON" do
      stub_reply("WARNING: something went sideways\n{\"ok\":true}")

      expect(backend.run("info")).to include("ok" => true)
    end

    it "raises the agent's own error message" do
      stub_reply('{"ok":false,"error":"boom"}')

      expect { backend.run("click") }
        .to raise_error(described_class::InteropError, /click: boom/)
    end

    it "raises when the agent prints no JSON at all" do
      stub_reply("", exitstatus: 1)

      expect { backend.run("info") }
        .to raise_error(described_class::InteropError, /returned no JSON/)
    end

    it "raises when the JSON is malformed" do
      stub_reply('{"ok":')

      expect { backend.run("info") }
        .to raise_error(described_class::InteropError, /unreadable JSON/)
    end

    it "raises when WSL has no Windows interop" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect { backend.run("info") }
        .to raise_error(described_class::InteropError, /cannot start/)
    end
  end

  describe "#cursor" do
    it "reads the pointer Windows reports" do
      stub_agent("ok" => true, "cursor" => { "x" => 300, "y" => 200 })

      expect(backend.cursor).to eq([300.0, 200.0])
    end

    it "returns nil when the agent has no cursor reading" do
      stub_agent("ok" => true)

      expect(backend.cursor).to be_nil
    end
  end

  describe "#key" do
    it "translates a combo into a virtual key plus modifiers" do
      sent = nil
      allow(backend).to receive(:run) { |_command, params| sent = params; { "ok" => true } }

      backend.key("ctrl+shift+t")

      expect(sent[:vk]).to eq(0x54)
      expect(sent[:modifiers]).to eq([0x11, 0x10])
      expect(sent[:repeat]).to eq(1)
    end

    it "accepts a combo whose main key is itself a modifier" do
      sent = nil
      allow(backend).to receive(:run) { |_command, params| sent = params; { "ok" => true } }

      backend.key("ctrl+shift")

      expect(sent[:vk]).to eq(0x10)
      expect(sent[:modifiers]).to eq([0x11])
    end

    it "rejects a key it cannot map" do
      expect { backend.key("nonsense") }.to raise_error(ArgumentError, /unknown key/)
    end
  end

  describe "#hold_key" do
    it "presses only the modifiers" do
      sent = nil
      allow(backend).to receive(:run) { |_command, params| sent = params; { "ok" => true } }

      backend.hold_key("shift", duration: 1.5)

      expect(sent[:modifiers]).to eq([0x10])
      expect(sent[:duration]).to eq(1.5)
    end

    it "refuses a combo with no modifier" do
      expect { backend.hold_key("t") }.to raise_error(ArgumentError, /no modifier keys/)
    end
  end

  describe "#diagnostics" do
    before { allow(backend).to receive(:interop_available?).and_return(true) }

    it "flags a capture that landed in session 0" do
      stub_agent("ok" => true, "session_id" => 0, "user" => "leo", "computer" => "BOX",
                 "cursor" => { "x" => 1, "y" => 2 }, "foreground" => "", "screens" => [])

      _lines, problems = backend.diagnostics

      expect(problems.join).to include("session 0")
    end

    it "stays quiet on a healthy interactive session" do
      stub_agent("ok" => true, "session_id" => 1, "user" => "leo", "computer" => "BOX",
                 "cursor" => { "x" => 1, "y" => 2 }, "foreground" => "Notepad",
                 "screens" => [{ "id" => 0, "primary" => true, "x" => 0, "y" => 0,
                                 "width" => 1512, "height" => 949 }])

      lines, problems = backend.diagnostics

      expect(problems).to be_empty
      expect(lines.join).to include("session: 1")
      expect(lines.join).to include("display 0 (main): 1512x949")
    end

    it "reports missing interop instead of failing" do
      allow(backend).to receive(:interop_available?).and_return(false)

      _lines, problems = backend.diagnostics

      expect(problems.join).to include("interop is unavailable")
    end
  end

  describe "capabilities" do
    it "never claims a missing permission, since Windows has no such gate" do
      expect(backend.missing_permissions).to eq([])
      expect(backend.screen_recording_allowed?).to be true
      expect(backend.accessibility_allowed?).to be true
    end
  end
end
