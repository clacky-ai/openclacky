# frozen_string_literal: true

require "socket"

module Clacky
  module Utils
    # Detects a running browser (Chrome/Edge) that has remote debugging enabled.
    #
    # Detection strategy:
    #
    #   1. Scan known UserData directories for DevToolsActivePort file.
    #      This file contains the exact port + WS path — most reliable.
    #      Returns { mode: :ws_endpoint, value: "ws://127.0.0.1:PORT/PATH" }
    #
    #   2. Verify the port is actually reachable via TCP probe.
    #
    #   3. Nothing found or port unreachable → returns nil (browser not running).
    #
    # Supported environments: WSL, Linux, macOS.
    module BrowserDetector

      # Detect a running debuggable browser.
      # Scans for DevToolsActivePort file across all platforms (macOS/Linux/WSL).
      # Returns the detected WebSocket endpoint only if the port is reachable.
      # @return [Hash] { mode: :ws_endpoint, value: String, status: :ok|:not_found }
      def self.detect
        os = EnvironmentDetector.os_type
        Clacky::Logger.debug("[BrowserDetector] Starting browser detection (OS: #{os})...")
        
        detected = detect_via_active_port_file
        
        unless detected
          Clacky::Logger.warn("[BrowserDetector] ✗ No reachable browser found")
          return { status: :not_found }
        end
        
        Clacky::Logger.info("[BrowserDetector] ✓ Browser detected and reachable: #{detected[:mode]} → #{detected[:value]}")
        detected.merge(status: :ok)
      end

      # -----------------------------------------------------------------------
      # Default browser identity (for browser-setup skill)
      # -----------------------------------------------------------------------
      #
      # Reads the OS-registered default browser identity — NOT navigator.userAgent.
      # This is the only reliable way to see through Chromium-shell browsers
      # (360, UC, Sogou, Quark, QQ …): they spoof their UA to look like plain
      # Chrome on third-party pages, but the system-level default-browser id they
      # register cannot be faked (e.g. 360 registers ProgID "360seURL").
      #
      #   macOS → LaunchServices https handler Bundle ID  (e.g. com.google.chrome)
      #   WSL   → Windows registry UserChoice ProgID       (e.g. ChromeHTML)
      #   Linux → xdg-settings default-web-browser .desktop (e.g. google-chrome.desktop)
      #
      # The returned :browser is a coarse label the skill can act on. We do NOT
      # block here — the browser-setup skill decides how to talk to the user.
      #
      # @return [Hash] { id: String|nil, browser: "chrome"|"edge"|"other"|"unknown" }

      # Whitelist of genuine, CDP-automatable browsers per platform.
      # Matched case-insensitively (macOS LaunchServices returns lowercase ids).
      # Verified by real-machine testing: com.google.chrome, com.microsoft.edgemac,
      # ChromeHTML, MSEdgeHTM (and 360seURL confirmed to fall outside).
      DEFAULT_BROWSER_WHITELIST = {
        macos: {
          "chrome" => ["com.google.chrome"],
          "edge"   => ["com.microsoft.edgemac"]
        },
        win: {
          "chrome" => ["chromehtml"],
          "edge"   => ["msedgehtm"]
        },
        linux: {
          "chrome" => [/\Agoogle-chrome/],
          "edge"   => [/\Amicrosoft-edge/]
        }
      }.freeze

      # @return [Hash] { id: String|nil, browser: String }
      def self.default_browser
        os = EnvironmentDetector.os_type
        id = case os
             when :macos        then macos_default_browser_id
             when :wsl          then win_default_browser_progid
             when :linux        then linux_default_browser_desktop
             end

        rules =
          case os
          when :macos        then DEFAULT_BROWSER_WHITELIST[:macos]
          when :wsl          then DEFAULT_BROWSER_WHITELIST[:win]
          when :linux        then DEFAULT_BROWSER_WHITELIST[:linux]
          end

        browser = classify_default_browser(id, rules)
        Clacky::Logger.info("[BrowserDetector] Default browser: id=#{id.inspect} → #{browser}")
        { id: id, browser: browser }
      end

      # Match a default-browser id against a platform whitelist.
      # @return [String] "chrome" | "edge" | "other" | "unknown"
      private_class_method def self.classify_default_browser(id, rules)
        return "unknown" if id.nil? || id.empty? || rules.nil?

        needle = id.downcase
        rules.each do |label, patterns|
          patterns.each do |p|
            matched = p.is_a?(Regexp) ? needle.match?(p) : needle == p
            return label if matched
          end
        end
        "other"
      end

      # macOS: read the https handler Bundle ID from LaunchServices.
      # Uses `plutil -extract LSHandlers json` + Ruby JSON (no Python dependency).
      # @return [String, nil] lowercase bundle id, e.g. "com.google.chrome"
      private_class_method def self.macos_default_browser_id
        plist = File.join(Dir.home,
                          "Library", "Preferences",
                          "com.apple.LaunchServices",
                          "com.apple.launchservices.secure.plist")
        return nil unless File.exist?(plist)

        out, _err, st = Open3.capture3("plutil", "-extract", "LSHandlers", "json", "-o", "-", plist)
        return nil unless st.success?

        handlers = JSON.parse(out)
        return nil unless handlers.is_a?(Array)

        https = handlers.find { |h| h.is_a?(Hash) && h["LSHandlerURLScheme"] == "https" }
        https&.dig("LSHandlerRoleAll")&.to_s&.downcase
      rescue StandardError => e
        Clacky::Logger.debug("[BrowserDetector] macOS default browser read failed: #{e.message}")
        nil
      end

      # WSL: read the Windows default-browser ProgID from the registry via
      # powershell.exe. The UserChoice key cannot be spoofed by shell browsers
      # (360 registers "360seURL" here, fully exposed).
      # @return [String, nil] ProgID, e.g. "ChromeHTML" / "MSEdgeHTM" / "360seURL"
      private_class_method def self.win_default_browser_progid
        cmd = '(Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice").ProgId'
        out = Utils::Encoding.cmd_to_utf8(
          `powershell.exe -NoProfile -Command #{Shellwords.escape(cmd)} 2>/dev/null`
        ).strip.tr("\r\n", "")
        out.empty? ? nil : out
      rescue StandardError => e
        Clacky::Logger.debug("[BrowserDetector] WSL default browser read failed: #{e.message}")
        nil
      end

      # Linux: read the default browser .desktop name via xdg-settings.
      # @return [String, nil] e.g. "google-chrome.desktop"
      private_class_method def self.linux_default_browser_desktop
        out = Utils::Encoding.cmd_to_utf8(
          `xdg-settings get default-web-browser 2>/dev/null`
        ).strip
        out.empty? ? nil : out
      rescue StandardError => e
        Clacky::Logger.debug("[BrowserDetector] Linux default browser read failed: #{e.message}")
        nil
      end

      # -----------------------------------------------------------------------
      # DevToolsActivePort file scan
      # -----------------------------------------------------------------------

      # @return [Hash, nil]
      def self.detect_via_active_port_file
        Clacky::Logger.debug("[BrowserDetector] Scanning UserData directories for DevToolsActivePort...")
        
        dirs = user_data_dirs
        Clacky::Logger.debug("[BrowserDetector] Candidate directories: #{dirs.size} found")
        
        dirs.each do |dir|
          port_file = File.join(dir, "DevToolsActivePort")
          next unless File.exist?(port_file)

          Clacky::Logger.debug("[BrowserDetector] Found DevToolsActivePort: #{port_file}")
          
          ws = parse_active_port_file(port_file)
          unless ws
            Clacky::Logger.debug("[BrowserDetector] ✗ Failed to parse #{port_file}")
            next
          end
          
          Clacky::Logger.debug("[BrowserDetector] Parsed WS endpoint: #{ws}")
          
          # ⭐️ Verify port BEFORE returning — skip stale files
          candidate = { mode: :ws_endpoint, value: ws }
          if verify_port(candidate)
            Clacky::Logger.debug("[BrowserDetector] ✓ Port is reachable, using this endpoint")
            return candidate
          else
            Clacky::Logger.debug("[BrowserDetector] ✗ Port not reachable, trying next directory...")
          end
        end
        
        Clacky::Logger.debug("[BrowserDetector] No reachable browser found")
        nil
      end

      # Verify that the detected browser port is actually reachable.
      # Extracts port from ws:// URL and attempts TCP connection.
      # @param detected [Hash] { mode: :ws_endpoint, value: String }
      # @return [Boolean] true if port is open and reachable
      def self.verify_port(detected)
        return false unless detected

        port = case detected[:mode]
        when :ws_endpoint
          # ws://127.0.0.1:9222/devtools/...
          detected[:value][/ws:\/\/127\.0\.0\.1:(\d+)/, 1]&.to_i
        end

        return false unless port && port > 0

        reachable = tcp_open?("127.0.0.1", port)
        Clacky::Logger.debug("[BrowserDetector] Port #{port} reachable: #{reachable}")
        reachable
      end

      # -----------------------------------------------------------------------
      # UserData directory candidates per OS
      # -----------------------------------------------------------------------

      # Returns ordered list of candidate UserData dirs to check.
      # @return [Array<String>]
      def self.user_data_dirs
        os = EnvironmentDetector.os_type
        Clacky::Logger.debug("[BrowserDetector] Detected OS: #{os}")
        
        case os
        when :wsl   then wsl_user_data_dirs
        when :linux then linux_user_data_dirs
        when :macos then macos_user_data_dirs
        else
          Clacky::Logger.warn("[BrowserDetector] Unknown OS type: #{os}")
          []
        end
      end

      # WSL: Chrome/Edge run on Windows side — resolve via LOCALAPPDATA.
      private_class_method def self.wsl_user_data_dirs
        appdata = Utils::Encoding.cmd_to_utf8(
          `powershell.exe -NoProfile -Command '$env:LOCALAPPDATA' 2>/dev/null`
        ).strip.tr("\r\n", "")
        return [] if appdata.empty?

        win_paths = [
          "#{appdata}\\Microsoft\\Edge\\User Data",
          "#{appdata}\\Google\\Chrome\\User Data",
          "#{appdata}\\Google\\Chrome Beta\\User Data",
          "#{appdata}\\Google\\Chrome SxS\\User Data",
        ]

        win_paths.filter_map do |win_path|
          linux_path = Utils::Encoding.cmd_to_utf8(
            `wslpath '#{win_path}' 2>/dev/null`, source_encoding: "UTF-8"
          ).strip
          linux_path.empty? ? nil : linux_path
        end
      end

      # Linux: standard XDG config paths for Chrome and Edge.
      private_class_method def self.linux_user_data_dirs
        config_home = ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config")
        [
          File.join(config_home, "microsoft-edge"),
          File.join(config_home, "google-chrome"),
          File.join(config_home, "google-chrome-beta"),
          File.join(config_home, "google-chrome-unstable"),
        ]
      end

      # macOS: Application Support paths for Chrome and Edge.
      private_class_method def self.macos_user_data_dirs
        base = File.join(Dir.home, "Library", "Application Support")
        [
          File.join(base, "Microsoft Edge"),
          File.join(base, "Google", "Chrome"),
          File.join(base, "Google", "Chrome Beta"),
          File.join(base, "Google", "Chrome Canary"),
        ]
      end

      # -----------------------------------------------------------------------
      # Helpers
      # -----------------------------------------------------------------------

      # Parse DevToolsActivePort file.
      # Format: first line = port number, second line = WS path
      # @return [String, nil] ws://127.0.0.1:PORT/PATH or nil on parse error
      private_class_method def self.parse_active_port_file(path)
        lines = File.read(path, encoding: "utf-8").split("\n").map(&:strip).reject(&:empty?)
        return nil unless lines.size >= 2

        port = lines[0].to_i
        ws_path = lines[1]
        return nil if port <= 0 || port > 65_535 || ws_path.empty?

        "ws://127.0.0.1:#{port}#{ws_path}"
      rescue StandardError
        nil
      end

      # Probe TCP port with a short timeout to verify port is actually reachable.
      # @param host [String] hostname
      # @param port [Integer] port number
      # @return [Boolean] true if port is open and reachable
      private_class_method def self.tcp_open?(host, port)
        Socket.tcp(host, port, connect_timeout: 0.5) { true }
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError, Errno::EHOSTUNREACH
        false
      end
    end
  end
end
