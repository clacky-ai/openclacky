# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "open3"
require "timeout"
require_relative "geometry"
require_relative "windows_keycodes"

module Clacky
  module Computer
    # Windows desktop backend, driven from inside WSL through interop.
    #
    # WHY interop rather than a native Windows build: Clacky runs inside WSL, and
    # WSL 2 has no display server that mirrors the Windows desktop, so the only
    # way to reach it is to start a Windows process. Interop children inherit the
    # session that launched WSL, which is what makes capture and input injection
    # land on the interactive desktop (session 1) instead of the invisible
    # session 0 where `CopyFromScreen` returns a blank frame and `wsl.exe` itself
    # refuses to run.
    #
    # WHY one PowerShell process per call: that startup is the single biggest
    # cost (~0.3-1s), so the Windows side takes a whole operation — capture plus
    # downscale plus grid, or a complete drag with interpolated moves — instead of
    # exposing chatty primitives.
    #
    # Coordinates are physical pixels of the virtual desktop, which is both the
    # space SetCursorPos consumes and the space a full-desktop capture produces,
    # so no scale factor is involved.
    class Windows
      class InteropError < ::Clacky::Computer::BackendError; end

      POWERSHELL = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
      AGENT_FILENAME = "windows_agent.ps1"
      SHARED_WSL_DIR = "/mnt/c/Users/Public/clacky-computer"
      SHOTS_WSL_DIR = "#{SHARED_WSL_DIR}/shots"
      WINDOWS_DRIVE = %r{\A/mnt/([a-z])/(.*)\z}
      DRIVE_LETTER = %r{\A([a-zA-Z]):[/\\](.*)\z}
      CALL_TIMEOUT = 90

      PERMISSION_HINT = "Start WSL from an interactive Windows desktop session — open Windows Terminal " \
                        "or PowerShell on the desktop and run `wsl` there. A WSL instance started by a " \
                        "service or scheduled task runs in session 0 and cannot see the desktop.".freeze

      # WSL reports itself in /proc/version; the /mnt/c check rules out a Linux
      # box that happens to mount a Windows share elsewhere.
      def self.wsl?
        platform = RUBY_PLATFORM
        return false unless platform.include?("linux")

        version = begin
          File.read("/proc/version")
        rescue StandardError
          ""
        end
        version.downcase.include?("microsoft") && File.directory?("/mnt/c/Windows")
      end

      def initialize
        @displays = nil
      end

      def interop_available?
        File.executable?(POWERSHELL)
      end

      # ---- capabilities ----

      # Windows has no TCC-style gate; the failure mode is a wrong desktop
      # session, which `diagnostics` reports instead.
      def screen_recording_allowed?
        true
      end

      def accessibility_allowed?
        true
      end

      def missing_permissions
        []
      end

      def require_permissions!
        true
      end

      def displays
        @displays ||= begin
          screens = run("info")["screens"]
          # PowerShell collapses a one-element array to an object on the way out.
          screens = [screens] if screens.is_a?(Hash)
          Array(screens).map do |screen|
            width = screen["width"].to_i
            height = screen["height"].to_i
            Geometry::Display.new(screen["id"].to_i, screen["x"].to_i, screen["y"].to_i,
                                  width, height, width, height,
                                  screen["primary"] ? true : false, false, true)
          end
        end
      end

      def cursor
        position = run("info")["cursor"]
        return nil unless position

        [position["x"].to_f, position["y"].to_f]
      end

      # ---- capture ----

      def capture(path:, display: nil, rect: nil, max_width: nil, grid_step: nil)
        rect = display.rect if rect.nil? && display
        target = windows_visible_path(path)
        params = { path: windows_path(target) }
        if rect
          x, y, width, height = rect
          params[:x] = x.round
          params[:y] = y.round
          params[:width] = width.round
          params[:height] = height.round
        end
        params[:max_width] = max_width.to_i if max_width && max_width.to_i > 0
        params[:grid_step] = grid_step.to_i if grid_step && grid_step.to_i > 0

        result = run("capture", params)
        Geometry::Capture.new(
          origin_x: result["origin_x"].to_f,
          origin_y: result["origin_y"].to_f,
          points_width: result["points_width"].to_f,
          points_height: result["points_height"].to_f,
          path: target,
          model_path: wsl_path(result["model_path"]),
          image_width: result["image_width"].to_i,
          image_height: result["image_height"].to_i
        )
      end

      # ---- input injection ----

      def move(x, y)
        run("move", x: x.round, y: y.round)
      end

      def click(x, y, button: "left", count: 1, modifiers: [])
        run("click", x: x.round, y: y.round, button: button.to_s, count: count.to_i,
                     modifiers: WindowsKeycodes.modifier_vks(modifiers))
      end

      def drag(from_x, from_y, to_x, to_y, button: "left", duration: 0.3)
        run("drag", from_x: from_x.round, from_y: from_y.round,
                   to_x: to_x.round, to_y: to_y.round, button: button.to_s)
      end

      def scroll(x, y, dx, dy)
        run("scroll", x: x.round, y: y.round, dx: dx.to_i, dy: dy.to_i)
      end

      def type(text)
        run("type", text: text.to_s)
        true
      end

      def key(combo, repeat: 1)
        modifiers, name = WindowsKeycodes.parse(combo)
        code = WindowsKeycodes.code_for(name)
        raise ArgumentError, "unknown key #{name.inspect} in #{combo.inspect}" if code.nil?

        run("key", vk: code, modifiers: WindowsKeycodes.modifier_vks(modifiers),
                   repeat: repeat.to_i)
        true
      end

      def hold_key(combo, duration: 1.0)
        modifiers, key = WindowsKeycodes.parse(combo)
        # `hold "shift"` names a lone modifier; parse reads a single part as the
        # key, so fold it back into the modifier list.
        modifiers = [key] if modifiers.empty? && WindowsKeycodes.modifier?(key)
        codes = WindowsKeycodes.modifier_vks(modifiers)
        raise ArgumentError, "no modifier keys in #{combo.inspect}" if codes.empty?

        run("hold", modifiers: codes, duration: duration.to_f)
        true
      end

      def activate(app_name, wait: 2.0)
        result = run("activate", app: app_name.to_s, wait: wait.to_f)
        [result["opened"], result["front"]]
      end

      # ---- diagnostics ----

      # Returns [lines, problems] for `doctor`: what the agent can see, and what
      # would make it silently useless.
      def diagnostics
        lines = []
        problems = []
        unless interop_available?
          problems << "Windows interop is unavailable (#{POWERSHELL} not found) — WSL 2 on Windows 11 is required"
          return [lines, problems]
        end

        info = run("info")
        session = info["session_id"].to_i
        lines << "windows session: #{session} (user #{info['user']}@#{info['computer']})"
        if session.zero?
          problems << "the agent is running in session 0, which has no desktop — #{PERMISSION_HINT}"
        end
        position = info["cursor"]
        lines << "cursor: #{position['x']},#{position['y']}" if position
        lines << "foreground window: #{info['foreground']}"
        displays.each do |display|
          lines << "display #{display.id}#{display.main ? ' (main)' : ''}: " \
                   "#{display.width}x#{display.height} at #{display.origin_x},#{display.origin_y}"
        end
        [lines, problems]
      end

      # ---- agent plumbing ----

      def run(command, params = {})
        ensure_agent!
        encoded = Base64.strict_encode64(JSON.generate(params))
        stdout, stderr, status = Timeout.timeout(CALL_TIMEOUT) do
          Open3.capture3(POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                         "-File", windows_path(agent_wsl_path),
                         "-Command", command.to_s, "-ParamsB64", encoded)
        end
        payload = parse_reply(stdout, stderr, status)
        raise InteropError, "#{command}: #{payload['error']}" unless payload["ok"]

        payload
      rescue Timeout::Error
        raise InteropError, "#{command}: the Windows agent did not answer within #{CALL_TIMEOUT}s"
      rescue Errno::ENOENT
        raise InteropError, "#{command}: cannot start #{POWERSHELL} — run WSL on a Windows host"
      end

      private def parse_reply(stdout, stderr, status)
        text = stdout.to_s
        match = text.match(/\{.*\}\s*\z/m)
        if match.nil?
          # A lone `{` means something JSON-shaped arrived but was cut short —
          # that points at the agent, not at the wrong program being launched.
          if text.include?("{")
            raise InteropError, "the Windows agent returned unreadable JSON: #{text.strip[0, 200]}"
          end

          detail = [stderr.to_s.strip, text.strip].reject(&:empty?).join(" / ")
          raise InteropError, "the Windows agent returned no JSON (exit #{status.exitstatus}): #{detail[0, 300]}"
        end

        JSON.parse(match[0])
      rescue JSON::ParserError
        raise InteropError, "the Windows agent returned unreadable JSON: #{match[0][0, 200]}"
      end

      private def agent_wsl_path
        File.join(SHARED_WSL_DIR, AGENT_FILENAME)
      end

      # The agent must run from a Windows path because it is PowerShell that
      # loads it, and PowerShell has no view of the WSL filesystem.
      private def ensure_agent!
        FileUtils.mkdir_p(SHARED_WSL_DIR)
        source = File.join(__dir__, AGENT_FILENAME)
        target = agent_wsl_path
        return if File.exist?(target) && File.read(target) == File.read(source)

        FileUtils.cp(source, target)
      end

      # A path the Windows side can open: anything already on a mounted drive
      # passes through, anything inside the WSL filesystem is relocated to the
      # shared directory so the capture is not lost.
      private def windows_visible_path(path)
        expanded = File.expand_path(path)
        return expanded if expanded.match?(WINDOWS_DRIVE)

        FileUtils.mkdir_p(SHOTS_WSL_DIR)
        File.join(SHOTS_WSL_DIR, File.basename(expanded))
      end

      private def windows_path(path)
        match = File.expand_path(path).match(WINDOWS_DRIVE)
        raise InteropError, "#{path} is not on a Windows drive" unless match

        "#{match[1].upcase}:\\#{match[2].tr('/', '\\')}"
      end

      private def wsl_path(path)
        match = path.to_s.match(DRIVE_LETTER)
        return path unless match

        "/mnt/#{match[1].downcase}/#{match[2].tr('\\', '/')}"
      end
    end
  end
end
