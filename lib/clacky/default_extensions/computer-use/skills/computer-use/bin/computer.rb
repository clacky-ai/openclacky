#!/usr/bin/env ruby
# frozen_string_literal: true

# Shell front-end for the computer-use extension.
#
# The agent drives the desktop through the `terminal` tool instead of a
# registered Ruby tool, which keeps ~1.2k tokens of tool schema out of every
# request. Each run is a fresh process, so the coordinate context travels
# through files: every capture writes a sidecar `.json` next to its PNG, and
# `last.json` in the state dir remembers the newest capture for commands that
# omit `--from`.

require "json"
require "fileutils"
require "securerandom"
require "tmpdir"
require "yaml"

# Resolved from this file's own location so the script works both in the repo
# and inside an installed gem (whose path carries the version number).
EXTENSION_ROOT = File.expand_path("../../..", __dir__)
require File.join(EXTENSION_ROOT, "lib", "computer", "geometry")

module ComputerUse
  EXIT_OK = 0
  EXIT_USAGE = 1
  EXIT_PERMISSION = 2
  EXIT_STATE = 3
  EXIT_DISABLED = 4

  STATE_DIR = File.join(Dir.tmpdir, "clacky-computer")
  SHOTS_DIR = File.join(STATE_DIR, "shots")
  LAST_STATE_PATH = File.join(STATE_DIR, "last.json")
  STATE_TTL_SECONDS = 120
  DEFAULT_MAX_WIDTH = 1512
  MAX_SCROLL_PIXELS = 5000
  MAX_WAIT_SECONDS = 30
  COORDINATE_TOLERANCE = 2
  CONFIG_PATH = File.join(Dir.home, ".clacky", "computer.yml")

  COMMANDS = %w[screenshot zoom click move drag scroll type key hold cursor activate doctor].freeze
  NUMBER = /\A-?\d+(\.\d+)?\z/
  DEFAULT_GRID_STEP = 200
  GRID_STEP_RANGE = (25..1000).freeze

  class UsageError < StandardError; end
  class StateError < StandardError; end

  class CLI
    def initialize(argv: ARGV, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = @argv.shift.to_s
      if command.empty? || %w[-h --help help].include?(command)
        @stdout.puts usage
        return command.empty? ? EXIT_USAGE : EXIT_OK
      end

      unless COMMANDS.include?(command)
        @stderr.puts "error: unknown command #{command.inspect}"
        @stderr.puts usage
        return EXIT_USAGE
      end

      if command != "doctor" && disabled_by_config?
        @stderr.puts "computer-use is switched off in #{CONFIG_PATH} (enabled: false)"
        return EXIT_DISABLED
      end

      positional, options = parse_argv(@argv)
      send("cmd_#{command}", positional, options) || EXIT_OK
    rescue UsageError => e
      @stderr.puts "error: #{e.message}"
      EXIT_USAGE
    rescue StateError => e
      @stderr.puts "error: #{e.message}"
      EXIT_STATE
    rescue Clacky::Computer::PermissionError => e
      @stderr.puts "permission: #{e.message}"
      EXIT_PERMISSION
    rescue Clacky::Computer::BackendError => e
      # Same code as a missing permission: both mean "the environment is not
      # ready", which is what the caller has to act on.
      @stderr.puts "error: #{e.message}"
      EXIT_PERMISSION
    rescue ArgumentError => e
      # A backend raises this for a key or combo it cannot map to a keycode.
      @stderr.puts "error: #{e.message}"
      EXIT_USAGE
    end

    private def cmd_screenshot(_positional, options)
      if options[:original] && options[:max_width]
        raise UsageError, "--original and --max-width are mutually exclusive"
      end

      max_width = if options[:original]
                    nil
                  else
                    options[:max_width] ? options[:max_width].to_i : DEFAULT_MAX_WIDTH
                  end
      grid_step = grid_step_for(options)
      capture = backend.capture(path: shot_path(options),
                                display: display_for(options[:display]),
                                max_width: max_width && max_width > 0 ? max_width : nil,
                                grid_step: grid_step)
      write_capture_state(capture)
      report_capture(capture)
      if options[:original]
        @stdout.puts "full resolution — read #{capture.model_path} with image_max_width: 0 " \
                     "(downscaling there would defeat --original)"
      end
      EXIT_OK
    end

    private def cmd_zoom(positional, options)
      source = capture_for(options)
      x1, y1, x2, y2 = parse_quad(positional, "zoom")
      left = source.image_to_points(x1, y1)
      right = source.image_to_points(x2, y2)
      rect = zoom_rect(left, right)
      grid_step = grid_step_for(options)

      capture = backend.capture(path: shot_path(options), rect: rect,
                                grid_step: grid_step)
      write_capture_state(capture)
      report_capture(capture)
    end

    private def cmd_click(positional, options)
      capture = capture_for(options)
      x, y = parse_pair(positional, "click")
      points_x, points_y = to_points(capture, x, y)
      button = (options[:button] || "left").to_s
      unless %w[left right middle].include?(button)
        raise UsageError, "--button must be left, right or middle"
      end

      count = options[:count] ? options[:count].to_i : 1
      raise UsageError, "--count must be 1..3" unless (1..3).cover?(count)

      backend.click(points_x, points_y, button: button, count: count,
                                       modifiers: split_list(options[:mods]))
      @stdout.puts "click #{button} x#{count} at #{points_x.round},#{points_y.round} points"
    end

    private def cmd_move(positional, options)
      capture = capture_for(options)
      x, y = parse_pair(positional, "move")
      points_x, points_y = to_points(capture, x, y)

      backend.move(points_x, points_y)
      @stdout.puts "moved to #{points_x.round},#{points_y.round} points"
    end

    private def cmd_drag(positional, options)
      capture = capture_for(options)
      from_x, from_y, to_x, to_y = parse_quad(positional, "drag")
      start_x, start_y = to_points(capture, from_x, from_y)
      end_x, end_y = to_points(capture, to_x, to_y)

      backend.drag(start_x, start_y, end_x, end_y)
      @stdout.puts "dragged #{start_x.round},#{start_y.round} -> #{end_x.round},#{end_y.round} points"
    end

    private def cmd_scroll(positional, options)
      capture = capture_for(options)
      x, y = parse_pair(positional, "scroll")
      points_x, points_y = to_points(capture, x, y)
      dx = options[:dx] ? options[:dx].to_i : 0
      dy = options[:dy] ? options[:dy].to_i : 0
      if dx.zero? && dy.zero?
        raise UsageError, "scroll needs --dx and/or --dy (positive dy scrolls up)"
      end

      if [dx.abs, dy.abs].max > MAX_SCROLL_PIXELS
        raise UsageError, "scroll is capped at #{MAX_SCROLL_PIXELS} px per call"
      end

      backend.scroll(points_x, points_y, dx, dy)
      @stdout.puts "scrolled dx #{dx} dy #{dy} at #{points_x.round},#{points_y.round} points"
    end

    private def cmd_type(positional, options)
      text = positional.join(" ")
      text = options[:text].to_s if text.empty? && options[:text]
      raise UsageError, 'type needs text, e.g. type "hello world"' if text.empty?

      backend.type(text)
      @stdout.puts "typed #{text.length} characters"
    end

    private def cmd_key(positional, options)
      combo = positional.first.to_s
      raise UsageError, 'key needs a combo, e.g. key "cmd+s"' if combo.strip.empty?

      repeat = options[:repeat] ? options[:repeat].to_i : 1
      raise UsageError, "--repeat must be 1..100" unless (1..100).cover?(repeat)

      backend.key(combo, repeat: repeat)
      @stdout.puts "pressed #{combo} x#{repeat}"
    end

    private def cmd_hold(positional, options)
      combo = positional.first.to_s
      raise UsageError, 'hold needs a key, e.g. hold "shift"' if combo.strip.empty?

      duration = options[:duration] ? options[:duration].to_f : 1.0
      raise UsageError, "--duration must be 0.05..#{MAX_WAIT_SECONDS} seconds" unless (0.05..MAX_WAIT_SECONDS).cover?(duration)

      backend.hold_key(combo, duration: duration)
      @stdout.puts "held #{combo} for #{duration}s"
    end

    # macOS exposes no way to read the pointer, and every run is a fresh process,
    # so there is nothing to report — say so instead of guessing. Windows does
    # expose it, so report the real thing there.
    private def cmd_cursor(_positional, _options)
      position = backend.cursor
      if position.nil?
        @stdout.puts "cursor position is unknown; take a screenshot and locate the pointer in the image"
        return EXIT_OK
      end

      @stdout.puts "cursor at #{position[0].round},#{position[1].round} points"
      EXIT_OK
    end

    private def cmd_activate(positional, options)
      app = positional.join(" ").to_s
      raise UsageError, 'activate needs an application name, e.g. activate "WorkBuddy"' if app.strip.empty?

      wait = options[:wait] ? options[:wait].to_f : 2.0
      unless (0.1..MAX_WAIT_SECONDS).cover?(wait)
        raise UsageError, "--wait must be 0.1..#{MAX_WAIT_SECONDS} seconds"
      end

      opened, front = backend.activate(app, wait: wait)
      unless opened
        @stderr.puts "error: cannot open #{app.inspect} — #{front}"
        return EXIT_USAGE
      end

      if front.to_s.casecmp?(app)
        @stdout.puts "activated #{app} (frontmost: #{front})"
      else
        @stdout.puts "asked the desktop to focus #{app}; frontmost is now #{front || 'unknown'}"
        @stdout.puts "take a screenshot to confirm the window you need is visible"
      end
      EXIT_OK
    end

    private def cmd_doctor(_positional, _options)
      @stdout.puts "platform: #{RUBY_PLATFORM}"
      @stdout.puts "kill switch: #{File.exist?(CONFIG_PATH) ? CONFIG_PATH : 'absent'}"
      @stdout.puts "enabled: #{disabled_by_config? ? 'no' : 'yes'}"

      # Resolving the backend is the step that fails on a host with no desktop —
      # it raises UsageError, which the CLI reports as a normal usage failure.
      # Keeping it last means the report still says which host it looked at.
      @stdout.puts "backend: #{backend.class.name.split('::').last}"
      lines, problems = backend.diagnostics
      lines.each { |line| @stdout.puts line }
      return EXIT_OK if problems.empty?

      problems.each { |problem| @stderr.puts "problem: #{problem}" }
      EXIT_PERMISSION
    end

    # ---- capture bookkeeping ----

    private def report_capture(capture)
      scale = capture.points_per_image_pixel_x.round(3)
      @stdout.puts "image #{capture.image_width}x#{capture.image_height} scale #{scale} " \
                   "origin (#{capture.origin_x.round}, #{capture.origin_y.round})"
      @stdout.puts "read #{capture.model_path}"
    end

    private def write_capture_state(capture)
      payload = {
        "image" => [capture.image_width, capture.image_height],
        "points" => [capture.points_width, capture.points_height],
        "origin" => [capture.origin_x, capture.origin_y],
        "path" => capture.path,
        "model_path" => capture.model_path,
        "created_at" => Time.now.to_f
      }
      atomic_write(sidecar_path(capture.path), JSON.generate(payload))
      atomic_write(LAST_STATE_PATH, JSON.generate(payload))
    end

    private def capture_for(options)
      payload = options[:from] ? read_sidecar(options[:from].to_s) : read_last_state
      Clacky::Computer::Geometry::Capture.new(
        origin_x: payload["origin"][0],
        origin_y: payload["origin"][1],
        points_width: payload["points"][0],
        points_height: payload["points"][1],
        path: payload["path"],
        model_path: payload["model_path"] || payload["path"],
        image_width: payload["image"][0],
        image_height: payload["image"][1]
      )
    end

    # The agent reads the model copy (path-1512.png, path-grid.png), but the
    # sidecar lives next to the capture the user passed to --out, so strip the
    # resample/grid suffixes before giving up.
    private def read_sidecar(png)
      candidates = [png.to_s]
      stripped = png.to_s.sub(/-grid\.png\z/i, ".png")
      candidates << stripped.sub(/-\d+\.png\z/i, ".png")
      candidates << stripped

      path = candidates.map { |candidate| sidecar_path(candidate) }.find { |candidate| File.exist?(candidate) }
      unless path
        raise StateError, "no coordinates recorded for #{png} — screenshot with `--out #{png}` first, " \
                          "or drop --from to use the most recent screenshot"
      end

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      raise StateError, "#{path} is unreadable — take a fresh screenshot"
    end

    private def read_last_state
      unless File.exist?(LAST_STATE_PATH)
        raise StateError, "no screenshot yet — run: ruby #{script_path} screenshot"
      end

      payload = JSON.parse(File.read(LAST_STATE_PATH))
      age = Time.now.to_f - payload["created_at"].to_f
      if age > STATE_TTL_SECONDS
        raise StateError, "the last screenshot is #{age.round}s old (limit #{STATE_TTL_SECONDS}s) — " \
                          "take a fresh one, or pass --from <png> to pin an older one"
      end

      payload
    rescue JSON::ParserError
      raise StateError, "#{LAST_STATE_PATH} is unreadable — take a fresh screenshot"
    end

    private def atomic_write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write(content)
      end
      File.rename(tmp, path)
    end

    private def sidecar_path(png)
      png.to_s.sub(/\.png\z/i, "") + ".json"
    end

    private def shot_path(options)
      return File.expand_path(options[:out].to_s) if options[:out]

      FileUtils.mkdir_p(SHOTS_DIR)
      File.join(SHOTS_DIR, "shot-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}.png")
    end

    # ---- geometry ----

    private def zoom_rect(left, right)
      width = (right[0] - left[0]).abs
      height = (right[1] - left[1]).abs
      pad_x = [width * 0.75, 25].max
      pad_y = [height * 0.75, 25].max
      rect = [(left[0] - pad_x).round, (left[1] - pad_y).round,
              (width + 2 * pad_x).round, (height + 2 * pad_y).round]
      rect[0] = [rect[0], 0].max
      rect[1] = [rect[1], 0].max
      rect[2] = 150 if rect[2] < 150
      rect[3] = 150 if rect[3] < 150
      rect
    end

    private def to_points(capture, x, y)
      unless capture.include?(x, y) ||
             (x >= -COORDINATE_TOLERANCE && y >= -COORDINATE_TOLERANCE &&
              x <= capture.image_width + COORDINATE_TOLERANCE &&
              y <= capture.image_height + COORDINATE_TOLERANCE)
        raise UsageError, "coordinate #{x},#{y} is outside the image " \
                          "(#{capture.image_width}x#{capture.image_height} px)"
      end

      capture.image_to_points(
        [[x, 0].max, capture.image_width - 1].min,
        [[y, 0].max, capture.image_height - 1].min
      )
    end

    private def parse_pair(values, label)
      numbers = split_numbers(values)
      unless numbers.length == 2
        raise UsageError, "#{label} needs two coordinates in the current image, e.g. #{label} 812 430"
      end

      numbers
    end

    private def parse_quad(values, label)
      numbers = split_numbers(values)
      unless numbers.length == 4
        raise UsageError, "#{label} needs four coordinates, e.g. #{label} 100 100 400 300"
      end

      numbers
    end

    private def grid_step_for(options)
      return nil unless options.key?(:grid)

      value = options[:grid]
      step = value == true ? DEFAULT_GRID_STEP : value.to_i
      unless GRID_STEP_RANGE.cover?(step)
        raise UsageError, "--grid must be #{GRID_STEP_RANGE.min}..#{GRID_STEP_RANGE.max} pixels"
      end

      step
    end

    private def split_numbers(values)
      parts = values.flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:empty?)
      parts.each do |part|
        raise UsageError, "#{part.inspect} is not a number" unless part.match?(NUMBER)
      end

      parts.map(&:to_f)
    end

    private def split_list(value)
      return [] if value.nil? || value == true

      value.to_s.split(/[+,\s]+/).map(&:strip).reject(&:empty?)
    end

    # ---- environment ----

    private def backend
      @backend ||= if RUBY_PLATFORM.include?("darwin")
                     require File.join(EXTENSION_ROOT, "lib", "computer", "macos")
                     Clacky::Computer::MacOS.new
                   else
                     require File.join(EXTENSION_ROOT, "lib", "computer", "windows")
                     unless Clacky::Computer::Windows.wsl?
                       raise UsageError, "computer-use drives the macOS desktop, or the Windows desktop " \
                                         "through WSL (running on #{RUBY_PLATFORM})"
                     end

                     Clacky::Computer::Windows.new
                   end
    end

    private def display_for(id)
      return nil if id.nil? || id == true

      display = backend.displays.find { |d| d.id == id.to_i }
      raise UsageError, "unknown display #{id}" if display.nil?

      display
    end

    private def disabled_by_config?
      return false unless File.exist?(CONFIG_PATH)

      config = YAML.safe_load(File.read(CONFIG_PATH))
      config.is_a?(Hash) && config["enabled"] == false
    rescue StandardError
      false
    end

    private def script_path
      File.expand_path(__FILE__)
    end

    private def parse_argv(argv)
      options = {}
      positional = []
      index = 0
      while index < argv.length
        arg = argv[index].to_s
        if arg.start_with?("--")
          name, inline = arg[2..-1].split("=", 2)
          key = name.tr("-", "_").to_sym
          if inline
            options[key] = inline
            index += 1
          elsif argv[index + 1] && !argv[index + 1].to_s.start_with?("--")
            options[key] = argv[index + 1]
            index += 2
          else
            options[key] = true
            index += 1
          end
        else
          positional << arg
          index += 1
        end
      end
      [positional, options]
    end

    private def usage
      <<~USAGE
        computer.rb — drive the desktop (macOS, or Windows through WSL)

        Usage: ruby computer.rb <command> [args] [--options]

          screenshot [--out FILE] [--display N] [--max-width W | --original] [--grid [STEP]]
          zoom X1 Y1 X2 Y2 [--from IMG] [--out FILE] [--grid [STEP]]
          click X Y [--from IMG] [--button left|right|middle] [--count N] [--mods cmd,shift]
          move X Y [--from IMG]
          drag X1 Y1 X2 Y2 [--from IMG]
          scroll X Y [--dx N] [--dy N] [--from IMG]
          type "text"
          key "cmd+shift+t" [--repeat N]
          hold "shift" [--duration SECONDS]
          cursor
          activate "AppName" [--wait SECONDS]
          doctor

        X/Y are pixels of the image printed by the last screenshot or zoom, origin
        top-left. Pass --from <png> to pin that image; otherwise the newest capture
        from the last #{STATE_TTL_SECONDS} seconds is used.

        --grid blends a labelled pixel grid over the screenshot (step defaults to
        #{DEFAULT_GRID_STEP}px) so coordinates can be read off the image directly.

        --original skips the downscale so the model copy is the full-resolution
        screenshot — read it with image_max_width: 0 (the read tool re-scales
        images to 800px otherwise). Costs many more tokens per image.

        Exit codes: 0 ok, 1 bad usage, 2 permission missing or backend unusable,
        3 screenshot state missing or stale, 4 disabled by #{CONFIG_PATH}.
      USAGE
    end
  end
end

exit ComputerUse::CLI.new.run if $PROGRAM_NAME == __FILE__
