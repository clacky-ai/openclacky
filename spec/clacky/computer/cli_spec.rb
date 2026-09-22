# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require File.expand_path(
  "../../../lib/clacky/default_extensions/computer-use/skills/computer-use/bin/computer.rb", __dir__
)

# Only the failure paths are covered here: every command that passes its
# checks ends with real mouse/keyboard injection, which a spec must not do.
RSpec.describe ComputerUse::CLI do
  let(:state_dir) { Dir.mktmpdir("clacky-computer-spec") }
  let(:config_path) { File.join(state_dir, "computer.yml") }
  let(:last_state_path) { File.join(state_dir, "last.json") }
  let(:png) { File.join(state_dir, "shot.png") }

  before do
    stub_const("ComputerUse::STATE_DIR", state_dir)
    stub_const("ComputerUse::SHOTS_DIR", File.join(state_dir, "shots"))
    stub_const("ComputerUse::LAST_STATE_PATH", last_state_path)
    stub_const("ComputerUse::CONFIG_PATH", config_path)
  end

  after do
    FileUtils.remove_entry(state_dir) if Dir.exist?(state_dir)
  end

  def run(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    code = described_class.new(argv: argv, stdout: stdout, stderr: stderr).run
    [code, stdout.string, stderr.string]
  end

  def capture_payload(width: 800, height: 600, age: 0.0)
    {
      "image" => [width, height],
      "points" => [width, height],
      "origin" => [0, 0],
      "path" => png,
      "model_path" => png,
      "created_at" => Time.now.to_f - age
    }
  end

  def write_state(path, payload)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(payload))
  end

  def sidecar_path(image)
    image.sub(/\.png\z/i, "") + ".json"
  end

  # A captured image plus the PNG placeholder it points at.
  def given_a_capture(age: 0.0)
    write_state(sidecar_path(png), capture_payload(age: age))
    File.write(png, "")
    png
  end

  describe "shell contract" do
    it "prints usage and fails when no command is given" do
      code, stdout, = run

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stdout).to include("Usage: ruby computer.rb")
      expect(stdout).to include("Exit codes:")
    end

    it "prints usage and succeeds for --help" do
      code, stdout, = run("--help")

      expect(code).to eq(ComputerUse::EXIT_OK)
      expect(stdout).to include("Usage: ruby computer.rb")
    end

    it "rejects an unknown command" do
      code, _stdout, stderr = run("wiggle")

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include('unknown command "wiggle"')
    end

    it "documents activate and --grid in usage" do
      code, stdout, = run("--help")

      expect(code).to eq(ComputerUse::EXIT_OK)
      expect(stdout).to include('activate "AppName"')
      expect(stdout).to include("--grid [STEP]")
    end

    it "documents --original in usage" do
      code, stdout, = run("--help")

      expect(code).to eq(ComputerUse::EXIT_OK)
      expect(stdout).to include("[--max-width W | --original]")
      expect(stdout).to include("image_max_width: 0")
    end

    it "answers cursor instead of guessing a pointer position" do
      code, stdout, stderr = run("cursor")

      if RUBY_PLATFORM.include?("darwin")
        expect(code).to eq(ComputerUse::EXIT_OK)
        expect(stdout).to include("unknown")
      else
        # Plain Linux has no desktop backend: only macOS and WSL-on-Windows do.
        expect(code).to eq(ComputerUse::EXIT_USAGE)
        expect(stderr).to include("WSL")
      end
    end
  end

  describe "kill switch" do
    it "refuses to act when computer.yml sets enabled: false" do
      File.write(config_path, "enabled: false\n")

      code, _stdout, stderr = run("click", "10", "10")

      expect(code).to eq(ComputerUse::EXIT_DISABLED)
      expect(stderr).to include("switched off")
    end

    it "ignores the kill switch for doctor" do
      File.write(config_path, "enabled: false\n")

      code, stdout, = run("doctor")

      expect(code).not_to eq(ComputerUse::EXIT_DISABLED)
      expect(stdout).to include("enabled: no")
    end

    it "stays open when computer.yml is unreadable" do
      File.write(config_path, "::: not yaml :::")

      code, _stdout, stderr = run("click", "10", "10")

      expect(code).to eq(ComputerUse::EXIT_STATE)
      expect(stderr).to include("no screenshot yet")
    end
  end

  describe "capture state" do
    it "asks for a screenshot when nothing was captured yet" do
      code, _stdout, stderr = run("click", "10", "10")

      expect(code).to eq(ComputerUse::EXIT_STATE)
      expect(stderr).to include("no screenshot yet")
    end

    it "refuses a stale last capture" do
      write_state(last_state_path, capture_payload(age: ComputerUse::STATE_TTL_SECONDS + 5))

      code, _stdout, stderr = run("click", "10", "10")

      expect(code).to eq(ComputerUse::EXIT_STATE)
      expect(stderr).to include("old")
    end

    it "refuses an unreadable last capture" do
      File.write(last_state_path, "{ truncated")

      code, _stdout, stderr = run("click", "10", "10")

      expect(code).to eq(ComputerUse::EXIT_STATE)
      expect(stderr).to include("unreadable")
    end

    it "asks for a matching screenshot when --from has no sidecar" do
      code, _stdout, stderr = run("click", "10", "10", "--from", png)

      expect(code).to eq(ComputerUse::EXIT_STATE)
      expect(stderr).to include("no coordinates recorded")
    end

    it "pins an older capture through --from" do
      given_a_capture(age: 9999)

      code, _stdout, stderr = run("click", "5000", "5000", "--from", png)

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("outside the image (800x600 px)")
    end

    it "resolves --from through the resample and grid suffixes" do
      given_a_capture

      grid_copy = png.sub(/\.png\z/i, "-1512-grid.png")
      code, _stdout, stderr = run("click", "5000", "5000", "--from", grid_copy)

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("outside the image (800x600 px)")
    end

    it "resolves --from through a bare grid suffix" do
      given_a_capture

      grid_copy = png.sub(/\.png\z/i, "-grid.png")
      code, _stdout, stderr = run("click", "5000", "5000", "--from", grid_copy)

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("outside the image (800x600 px)")
    end
  end

  describe "argument checks" do
    let!(:capture) { given_a_capture }

    it "rejects an incomplete coordinate pair" do
      code, _stdout, stderr = run("move", "40", "--from", png)

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("needs two coordinates")
    end

    it "rejects a non-numeric coordinate" do
      code, _stdout, stderr = run("move", "left", "12", "--from", png)

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("is not a number")
    end

    it "rejects an incomplete zoom rectangle" do
      code, _stdout, stderr = run("zoom", "1", "2", "3", "--from", png)

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("needs four coordinates")
    end

    it "rejects an unknown mouse button" do
      code, _stdout, stderr = run("click", "10", "10", "--button", "side", "--from", png)

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("--button must be")
    end

    it "rejects an out-of-range click count" do
      code, _stdout, stderr = run("click", "10", "10", "--count", "4", "--from", png)

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("--count must be 1..3")
    end

    it "rejects a scroll without a delta" do
      code, _stdout, stderr = run("scroll", "10", "10", "--from", png)

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("scroll needs --dx and/or --dy")
    end

    it "caps a single scroll" do
      code, _stdout, stderr = run("scroll", "10", "10", "--dy", "6000", "--from", png)

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("capped at 5000 px")
    end

    it "rejects empty text" do
      code, _stdout, stderr = run("type")

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("type needs text")
    end

    it "rejects an empty key combo" do
      code, _stdout, stderr = run("key")

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("key needs a combo")
    end

    it "rejects an out-of-range repeat count" do
      code, _stdout, stderr = run("key", "cmd+s", "--repeat", "0")

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("--repeat must be 1..100")
    end

    it "rejects an out-of-range hold duration" do
      code, _stdout, stderr = run("hold", "shift", "--duration", "0.01")

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("--duration must be 0.05..")
    end

    it "rejects activate without an application name" do
      code, _stdout, stderr = run("activate")

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("activate needs an application name")
    end

    it "rejects an out-of-range activate wait" do
      code, _stdout, stderr = run("activate", "WorkBuddy", "--wait", "99")

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("--wait must be 0.1..")
    end

    it "rejects an out-of-range grid step" do
      code, _stdout, stderr = run("screenshot", "--grid", "10")

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("--grid must be 25..1000 pixels")
    end

    it "rejects --original together with --max-width" do
      code, _stdout, stderr = run("screenshot", "--original", "--max-width", "800")

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("mutually exclusive")
    end

    it "rejects an out-of-range grid step on zoom" do
      code, _stdout, stderr = run("zoom", "10", "10", "20", "20", "--from", png, "--grid", "2000")

      expect(code).to eq(ComputerUse::EXIT_USAGE)
      expect(stderr).to include("--grid must be 25..1000 pixels")
    end
  end

  describe "doctor" do
    it "reports the platform, backend and health" do
      code, stdout, stderr = run("doctor")

      expect(stdout).to include("platform: #{RUBY_PLATFORM}")
      expect(stdout).to include("kill switch: absent")

      if RUBY_PLATFORM.include?("darwin")
        expect(stdout).to include("backend: MacOS")
        expect(stdout).to include("screen recording:")
        expect(stdout).to include("accessibility:")
        expect([ComputerUse::EXIT_OK, ComputerUse::EXIT_PERMISSION]).to include(code)
        expect(stderr).to include("permission is missing") if code == ComputerUse::EXIT_PERMISSION
      else
        # Plain Linux has no desktop backend: only macOS and WSL-on-Windows do.
        expect(code).to eq(ComputerUse::EXIT_USAGE)
        expect(stderr).to include("WSL")
      end
    end
  end
end
