# frozen_string_literal: true

require "shellwords"
require "yaml"
require "tmpdir"
require "json"
require "open3"
require "socket"
require "net/http"
require_relative "base"
require_relative "shell"

module Clacky
  module Tools
    # Detects the user's default Chromium-based browser and resolves its
    # userDataDir so we can read DevToolsActivePort and connect to the
    # running browser directly — identical to how openclaw does it.
    module ChromiumDetector
      # Minimum Chromium major version that supports the attach consent dialog
      # (the "Allow remote debugging?" popup that lets us connect without
      # pre-launching Chrome with --remote-debugging-port).
      MIN_CHROMIUM_MAJOR = 144

      # macOS Launch Services plist — records which app handles http/https
      MAC_LS_PLIST = File.expand_path(
        "~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"
      )

      # Known Chromium-based bundle IDs on macOS, in rough priority order.
      # Note: Edge on macOS uses "com.microsoft.edgemac" (not "com.microsoft.Edge").
      MAC_CHROMIUM_BUNDLE_IDS = {
        "com.google.Chrome"                  => :chrome,
        "com.google.Chrome.beta"             => :chrome,
        "com.google.Chrome.canary"           => :chrome,
        "com.google.Chrome.dev"              => :chrome,
        "com.microsoft.edgemac"              => :edge,   # real macOS bundle ID
        "com.microsoft.edgemac.Beta"         => :edge,
        "com.microsoft.edgemac.Dev"          => :edge,
        "com.microsoft.edgemac.Canary"       => :edge,
        "com.microsoft.Edge"                 => :edge,   # kept for compatibility
        "com.microsoft.EdgeBeta"             => :edge,
        "com.microsoft.EdgeDev"              => :edge,
        "com.microsoft.EdgeCanary"           => :edge,
        "com.brave.Browser"                  => :brave,
        "com.brave.Browser.beta"             => :brave,
        "com.brave.Browser.nightly"          => :brave,
        "org.chromium.Chromium"              => :chromium,
        "com.vivaldi.Vivaldi"                => :chromium,
        "com.operasoftware.Opera"            => :chromium,
        "com.operasoftware.OperaGX"          => :chromium,
        "com.yandex.desktop.yandex-browser"  => :chromium,
        "company.thebrowser.Browser"         => :chromium, # Arc
      }.freeze

      # macOS userDataDir per browser kind.
      # Edge stores data under "Microsoft Edge", not "msedge".
      MAC_USER_DATA_DIRS = {
        chrome:   "~/Library/Application Support/Google/Chrome",
        edge:     "~/Library/Application Support/Microsoft Edge",
        brave:    "~/Library/Application Support/BraveSoftware/Brave-Browser",
        chromium: "~/Library/Application Support/Chromium",
      }.freeze

      # Fallback app paths to search when default browser is not Chromium
      MAC_FALLBACK_BROWSERS = [
        { kind: :chrome,   path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" },
        { kind: :chrome,   path: "~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" },
        { kind: :edge,     path: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" },
        { kind: :edge,     path: "~/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" },
        { kind: :brave,    path: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" },
        { kind: :brave,    path: "~/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" },
        { kind: :chromium, path: "/Applications/Chromium.app/Contents/MacOS/Chromium" },
        { kind: :chromium, path: "~/Applications/Chromium.app/Contents/MacOS/Chromium" },
      ].freeze

      # Linux .desktop IDs that belong to Chromium-based browsers
      LINUX_CHROMIUM_DESKTOP_IDS = %w[
        google-chrome.desktop
        google-chrome-beta.desktop
        google-chrome-unstable.desktop
        brave-browser.desktop
        microsoft-edge.desktop
        microsoft-edge-beta.desktop
        microsoft-edge-dev.desktop
        chromium.desktop
        chromium-browser.desktop
        vivaldi.desktop
        vivaldi-stable.desktop
        opera.desktop
        org.chromium.Chromium.desktop
      ].freeze

      # Linux userDataDir per desktop-id kind
      LINUX_USER_DATA_DIRS = {
        chrome:   "~/.config/google-chrome",
        edge:     "~/.config/microsoft-edge",
        brave:    "~/.config/BraveSoftware/Brave-Browser",
        chromium: "~/.config/chromium",
      }.freeze

      # Windows AppData paths (resolved at runtime via ENV)
      # Returns {kind: Symbol, user_data_dir: String} or nil
      def self.detect
        case RUBY_PLATFORM
        when /darwin/
          detect_mac
        when /linux/
          detect_linux
        when /mswin|mingw|cygwin/
          detect_windows
        end
      end

      # --- macOS ---

      def self.detect_mac
        bundle_id = mac_default_browser_bundle_id
        kind = bundle_id && MAC_CHROMIUM_BUNDLE_IDS[bundle_id]

        if kind
          user_data_dir = File.expand_path(MAC_USER_DATA_DIRS[kind])
          # No version check here — Stage 2/3 (DevToolsActivePort) validates connectivity.
          # Version check via osascript is too slow (1-2 s) for the hot path.
          return { kind: kind, user_data_dir: user_data_dir, default_is_chromium: true }
        end

        # Default browser is not Chromium — search installed fallback browsers.
        fallback = mac_fallback_chromium
        fallback&.merge(default_is_chromium: false)
      end

      private_class_method def self.mac_default_browser_bundle_id
        return nil unless File.exist?(MAC_LS_PLIST)

        raw = run_cmd("/usr/bin/plutil",
                      "-extract", "LSHandlers", "json", "-o", "-", "--", MAC_LS_PLIST)
        return nil unless raw

        handlers = JSON.parse(raw) rescue nil
        return nil unless handlers.is_a?(Array)

        %w[http https].each do |scheme|
          handlers.each do |entry|
            next unless entry.is_a?(Hash) && entry["LSHandlerURLScheme"] == scheme
            id = entry["LSHandlerRoleAll"] || entry["LSHandlerRoleViewer"]
            return id if id
          end
        end
        nil
      end

      private_class_method def self.mac_browser_version_for_bundle(bundle_id)
        app_path_raw = run_cmd("/usr/bin/osascript",
                               "-e", %(POSIX path of (path to application id "#{bundle_id}")))
        return nil unless app_path_raw

        app_path = app_path_raw.strip.chomp("/")
        exe_name = run_cmd("/usr/bin/defaults",
                           "read", "#{app_path}/Contents/Info", "CFBundleShortVersionString")
        return nil unless exe_name

        exe_name.strip
      end

      private_class_method def self.mac_fallback_chromium
        MAC_FALLBACK_BROWSERS.each do |entry|
          path = File.expand_path(entry[:path])
          next unless File.executable?(path)

          user_data_dir = File.expand_path(MAC_USER_DATA_DIRS[entry[:kind]])
          return { kind: entry[:kind], user_data_dir: user_data_dir }
        end
        nil
      end

      # --- Linux ---

      def self.detect_linux
        desktop_id = linux_default_desktop_id
        kind = linux_kind_from_desktop_id(desktop_id)

        if kind
          user_data_dir = File.expand_path(LINUX_USER_DATA_DIRS[kind])
          return { kind: kind, user_data_dir: user_data_dir, default_is_chromium: true }
        end

        fallback = linux_fallback_chromium
        fallback&.merge(default_is_chromium: false)
      end

      private_class_method def self.linux_default_desktop_id
        id = run_cmd("xdg-settings", "get", "default-web-browser") ||
             run_cmd("xdg-mime", "query", "default", "x-scheme-handler/http")
        id&.strip
      end

      private_class_method def self.linux_kind_from_desktop_id(desktop_id)
        return nil unless desktop_id && LINUX_CHROMIUM_DESKTOP_IDS.include?(desktop_id)

        case desktop_id
        when /brave/    then :brave
        when /edge/     then :edge
        when /chromium/ then :chromium
        else                 :chrome
        end
      end

      private_class_method def self.linux_fallback_chromium
        candidates = [
          { kind: :chrome,   path: "/usr/bin/google-chrome" },
          { kind: :chrome,   path: "/usr/bin/google-chrome-stable" },
          { kind: :brave,    path: "/usr/bin/brave-browser" },
          { kind: :edge,     path: "/usr/bin/microsoft-edge" },
          { kind: :chromium, path: "/usr/bin/chromium" },
          { kind: :chromium, path: "/usr/bin/chromium-browser" },
          { kind: :chromium, path: "/snap/bin/chromium" },
        ]
        candidates.each do |entry|
          next unless File.executable?(entry[:path])
          user_data_dir = File.expand_path(LINUX_USER_DATA_DIRS[entry[:kind]])
          return { kind: entry[:kind], user_data_dir: user_data_dir }
        end
        nil
      end

      # --- Windows ---

      def self.detect_windows
        local_app_data = ENV["LOCALAPPDATA"] || ""
        return nil if local_app_data.empty?

        # On Windows we only scan for known Chromium-based browsers.
        # All successfully detected browsers count as default_is_chromium: true
        # because we have no reliable way to detect the OS default browser here.
        candidates = [
          { kind: :chrome,   dir: File.join(local_app_data, "Google", "Chrome", "User Data") },
          { kind: :edge,     dir: File.join(local_app_data, "Microsoft", "Edge", "User Data") },
          { kind: :brave,    dir: File.join(local_app_data, "BraveSoftware", "Brave-Browser", "User Data") },
          { kind: :chromium, dir: File.join(local_app_data, "Chromium", "User Data") },
        ]
        candidates.each do |entry|
          # Check if the UserData dir exists (browser installed and has been used)
          next unless File.directory?(entry[:dir])
          return { kind: entry[:kind], user_data_dir: entry[:dir], default_is_chromium: true }
        end
        nil
      end

      # --- Helpers ---

      private_class_method def self.chromium_version_ok?(version_str)
        return true if version_str.nil? # unknown version — optimistically allow
        major = version_str.to_s.match(/(\d+)/)&.[](1).to_i
        major == 0 || major >= MIN_CHROMIUM_MAJOR
      end

      private_class_method def self.run_cmd(*args)
        out, _err, status = Open3.capture3(*args.map(&:to_s))
        status.success? ? out.strip : nil
      rescue StandardError
        nil
      end
    end

    class Browser < Base
      self.tool_name = "browser"
      self.tool_description = <<~DESC
        Control the browser for automation tasks (login, form submission, UI interaction, scraping).
        For simple page fetch or search, prefer web_fetch or web_search instead.

        PROFILES — choose the right browser context:
        - profile="user"    → your real browser (Chrome/Edge/Brave) with existing logins & cookies. Use when you need to be already logged in. Requires Chromium v144+.
        - profile="sandbox" → isolated sandboxed browser (default, no cookies). Use for anonymous browsing or when login state doesn't matter.

        ACTIONS OVERVIEW:
        - snapshot   → get accessibility tree with element refs (@e1, @e2...). ALWAYS run before interacting.
        - act        → interact with page: click, type, fill, press, hover, scroll, drag, select, wait, evaluate
        - open       → navigate to URL (opens new tab in user profile, navigates in sandbox)
        - navigate   → navigate current tab to URL
        - tabs       → list open tabs
        - focus      → switch to a tab by targetId
        - close      → close current tab (or browser)
        - screenshot → capture screenshot. NEVER call without user approval first (high token cost).
        - pdf        → save page as PDF to a file path
        - upload     → upload a file via file input element
        - dialog     → respond to alert/confirm/prompt dialogs (accept/dismiss)
        - console    → read browser console logs (useful for debugging JS errors)
        - status     → check if browser is running
        - start      → start the browser
        - stop       → stop the browser

        SNAPSHOT WORKFLOW — always snapshot first:
        - action="snapshot"                            → full accessibility tree
        - action="snapshot", interactive=true          → interactive elements only (faster, recommended)
        - action="snapshot", interactive=true, compact=true → compact interactive (best for most tasks)
        - action="snapshot", selector="#main"          → scope to a CSS selector

        ELEMENT SELECTION in act — prefer in this order:
        1. Refs from snapshot: ref="@e1"
        2. Semantic find:      selector='find role button "Submit"' or selector='find label "Email"'
        3. CSS selector:       selector="#submit-btn"

        ACT KINDS: click, type, fill, press, hover, drag, select, scroll, scrollintoview, wait, evaluate, close
        - click:         ref="@e1" (or selector=)
        - type/fill:     ref="@e1", text="value"  (fill clears first, type appends)
        - press:         key="Enter" (or "Control+a", "Tab", etc.)
        - scroll:        direction="down" (up/down/left/right), amount=300
        - wait:          ms=2000 (wait N ms) OR selector=".spinner" (wait for element) OR load_state="networkidle"
        - evaluate:      js="document.title"  → executes JS and returns result
        - drag:          ref="@e1", target_ref="@e2"

        TARGETING TABS — pass target_id from snapshot/tabs response to subsequent acts:
        After action="open" or action="tabs", store the returned targetId and pass it to act/snapshot.
        This ensures you operate on the correct tab even when multiple tabs are open.

        SCREENSHOT — last resort only. Ask user first: "Screenshots cost more tokens. Approve?"
        When approved: action="screenshot", format="jpeg", quality=50
      DESC
      self.tool_category = "web"
      self.tool_parameters = {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: %w[snapshot act open navigate tabs focus close screenshot pdf upload dialog console status start stop],
            description: "Action to perform."
          },
          profile: {
            type: "string",
            enum: %w[sandbox user],
            description: "Browser profile. 'user' = real browser with logins/cookies (Chromium v144+ required). 'sandbox' = isolated (default)."
          },
          # snapshot options
          interactive: {
            type: "boolean",
            description: "snapshot: only include interactive elements (recommended, reduces noise)."
          },
          compact: {
            type: "boolean",
            description: "snapshot: remove empty structural elements for a cleaner tree."
          },
          cursor: {
            type: "boolean",
            description: "snapshot: include cursor-clickable elements (cursor:pointer, onclick, tabindex)."
          },
          depth: {
            type: "integer",
            description: "snapshot: max tree depth to include."
          },
          selector: {
            type: "string",
            description: "snapshot: scope to a CSS selector. act: CSS/ref selector for the target element."
          },
          # act options
          kind: {
            type: "string",
            enum: %w[click dblclick type fill press hover drag select scroll scrollintoview wait evaluate close check uncheck],
            description: "act: the interaction kind."
          },
          ref: {
            type: "string",
            description: "act: element ref from snapshot (e.g. '@e1'). Preferred over selector."
          },
          text: {
            type: "string",
            description: "act type/fill: text to type or fill into the element."
          },
          key: {
            type: "string",
            description: "act press: key to press (e.g. 'Enter', 'Tab', 'Control+a')."
          },
          direction: {
            type: "string",
            enum: %w[up down left right],
            description: "act scroll: scroll direction."
          },
          amount: {
            type: "integer",
            description: "act scroll: pixels to scroll."
          },
          ms: {
            type: "integer",
            description: "act wait: milliseconds to wait."
          },
          load_state: {
            type: "string",
            enum: %w[load domcontentloaded networkidle],
            description: "act wait: wait for a specific page load state."
          },
          js: {
            type: "string",
            description: "act evaluate: JavaScript expression to execute. Returns the result."
          },
          target_ref: {
            type: "string",
            description: "act drag: destination element ref."
          },
          values: {
            type: "array",
            items: { type: "string" },
            description: "act select: option values to select in a <select> element."
          },
          double_click: {
            type: "boolean",
            description: "act click: if true, perform a double-click."
          },
          # open / navigate / tabs / focus
          url: {
            type: "string",
            description: "open/navigate: URL to navigate to."
          },
          target_id: {
            type: "string",
            description: "focus/act/snapshot: target tab ID returned by open or tabs. Pass this to operate on a specific tab."
          },
          # screenshot
          format: {
            type: "string",
            enum: %w[png jpeg],
            description: "screenshot: image format (default jpeg)."
          },
          quality: {
            type: "integer",
            description: "screenshot: JPEG quality 0-100 (default 50)."
          },
          full_page: {
            type: "boolean",
            description: "screenshot: capture full scrollable page."
          },
          # pdf
          path: {
            type: "string",
            description: "pdf: file path to save the PDF."
          },
          # upload
          files: {
            type: "array",
            items: { type: "string" },
            description: "upload: local file paths to upload."
          },
          # dialog
          response: {
            type: "string",
            enum: %w[accept dismiss],
            description: "dialog: accept or dismiss the dialog."
          },
          prompt_text: {
            type: "string",
            description: "dialog accept: optional text to fill in a prompt dialog."
          }
        },
        required: ["action"]
      }

      AGENT_BROWSER_BIN = "agent-browser"
      BROWSER_COMMAND_TIMEOUT = 30
      MIN_AGENT_BROWSER_VERSION = "0.20.0"

      # DevToolsActivePort poll settings — Chrome/Edge 144+ writes this file
      # after the user clicks "Allow" in the attach consent dialog.
      #
      # Two wait budgets:
      #   SHORT — browser just restarted; CDP is already enabled (user-enabled=true)
      #           and the server starts quickly. 5 s is plenty.
      #   LONG  — user needs to open edge://inspect and tick the checkbox
      #           (user-enabled=false). We give them 45 s to find and click it.
      DEV_TOOLS_PORT_WAIT_SECS_SHORT = 5
      DEV_TOOLS_PORT_WAIT_SECS_LONG  = 45
      DEV_TOOLS_PORT_POLL_INTERVAL   = 0.3

      # Inline config — reads ~/.clacky/browser.yml, falls back to built-in defaults.
      #
      # Example ~/.clacky/browser.yml:
      #   headed: true          # show browser window (default: true)
      #   session_name: clacky  # persistent session name (default: clacky)
      class BrowserConfig
        USER_CONFIG_FILE = File.join(Dir.home, ".clacky", "browser.yml")

        DEFAULTS = {
          "headed"       => true,
          "session_name" => "clacky"
        }.freeze

        attr_reader :headed, :session_name

        def initialize(attrs = {})
          merged = DEFAULTS.merge(attrs)
          @headed       = merged["headed"]
          @session_name = merged["session_name"]
        end

        def self.load
          data = File.exist?(USER_CONFIG_FILE) ? YAML.safe_load(File.read(USER_CONFIG_FILE)) || {} : {}
          new(data)
        rescue StandardError
          new
        end
      end

      def execute(action:, profile: nil, working_dir: nil, **opts)
        unless agent_browser_ready?
          return not_ready_response
        end

        cfg = BrowserConfig.load
        use_user_profile = profile.to_s == "user"

        # Resolve connection flags depending on profile selection.
        # user   → try CDP to user's real browser; fall back to sandbox if unreachable.
        # sandbox (default) → agent-browser's own isolated Chromium session.
        cdp_port = nil
        browser_info = nil

        if use_user_profile
          browser_info = ChromiumDetector.detect
          cdp_port     = resolve_user_browser_cdp_port(browser_info)
        end

        # Build the agent-browser subcommand string from the structured action.
        ab_command = build_action_command(action, opts, real_browser: cdp_port)

        if cdp_port
          full_command = build_command(ab_command, cdp_port: cdp_port)
          result = Shell.new.execute(command: full_command,
                                     hard_timeout: BROWSER_COMMAND_TIMEOUT,
                                     working_dir: working_dir)

          if result[:success] || !user_browser_connect_error?(result)
            result[:action]       = action
            result[:browser_mode] = :user_browser
            return format_result_hash(result)
          end
          # CDP connection lost — fall through to sandbox
        end

        # Sandbox path
        full_command = build_command(ab_command,
                                     session_name: cfg.session_name,
                                     headed:       cfg.headed)
        result = Shell.new.execute(command: full_command,
                                   hard_timeout: BROWSER_COMMAND_TIMEOUT,
                                   working_dir: working_dir)

        # Session may have been closed — retry without session name
        if !result[:success] && session_closed_error?(result) && cfg.session_name
          full_command = build_command(ab_command, headed: cfg.headed)
          result = Shell.new.execute(command: full_command,
                                     hard_timeout: BROWSER_COMMAND_TIMEOUT,
                                     working_dir: working_dir)
        end

        result[:action]       = action
        result[:browser_mode] = :sandbox
        result[:browser_notice] = sandbox_fallback_notice(browser_info) if use_user_profile

        format_result_hash(result)
      rescue StandardError => e
        { error: "Failed to run agent-browser: #{e.message}" }
      end

      def format_call(args)
        action  = args[:action]  || args["action"]  || "browser"
        profile = args[:profile] || args["profile"]
        suffix  = profile ? "(#{action}, profile=#{profile})" : "(#{action})"
        "browser#{suffix}"
      end

      def format_result(result)
        if result[:error]
          "[Error] #{result[:error][0..80]}"
        elsif result[:success]
          stdout = result[:stdout] || ""
          lines  = stdout.lines.size
          "[OK] #{lines > 0 ? "#{lines} lines" : "Done"}"
        else
          stderr = result[:stderr] || "Failed"
          "[Failed] #{stderr[0..80]}"
        end
      end

      MAX_LLM_OUTPUT_CHARS = 6000
      MAX_SNAPSHOT_CHARS   = 4000

      def format_result_for_llm(result)
        return result if result[:error]

        stdout       = result[:stdout] || ""
        stderr       = result[:stderr] || ""
        action       = result[:action].to_s
        command_name = action.empty? ? "browser" : action

        compact = {
          action:    action,
          success:   result[:success],
          exit_code: result[:exit_code]
        }

        if action == "snapshot"
          stdout    = compress_snapshot(stdout)
          max_chars = MAX_SNAPSHOT_CHARS
        else
          max_chars = MAX_LLM_OUTPUT_CHARS
        end

        stdout_info = truncate_and_save(stdout, max_chars, "stdout", command_name)
        compact[:stdout]      = stdout_info[:content]
        compact[:stdout_full] = stdout_info[:temp_file] if stdout_info[:temp_file]

        stderr_info = truncate_and_save(stderr, 500, "stderr", command_name)
        compact[:stderr]      = stderr_info[:content] unless stderr.empty?
        compact[:stderr_full] = stderr_info[:temp_file] if stderr_info[:temp_file]

        compact[:browser_notice] = result[:browser_notice] if result[:browser_notice]
        compact[:browser_mode]   = result[:browser_mode]   if result[:browser_mode]

        compact
      end

      private

      # -----------------------------------------------------------------------
      # Action → agent-browser command string translation
      # -----------------------------------------------------------------------

      # Translates the structured action + options into an agent-browser CLI command.
      # Returns a string like "snapshot -i -C" or "click @e1".
      private def build_action_command(action, opts, real_browser: nil)
        case action.to_s
        when "snapshot"
          build_snapshot_command(opts)
        when "act"
          build_act_command(opts)
        when "open"
          url = opts[:url] || opts["url"] || ""
          # In real-browser mode open a new tab so we don't hijack the user's current page
          real_browser ? "tab new #{Shellwords.escape(url)}" : "open #{Shellwords.escape(url)}"
        when "navigate"
          url = opts[:url] || opts["url"] || ""
          "open #{Shellwords.escape(url)}"
        when "tabs"
          "tab list"
        when "focus"
          target_id = opts[:target_id] || opts["target_id"] || ""
          # agent-browser switches to tab by index; target_id can be index or a ref
          "tab #{Shellwords.escape(target_id)}"
        when "close"
          "close"
        when "screenshot"
          build_screenshot_command(opts)
        when "pdf"
          path = opts[:path] || opts["path"] || "page.pdf"
          "pdf #{Shellwords.escape(path)}"
        when "upload"
          ref      = opts[:ref]      || opts["ref"]      || ""
          selector = opts[:selector] || opts["selector"] || ""
          files    = Array(opts[:files] || opts["files"] || [])
          target   = ref.empty? ? Shellwords.escape(selector) : Shellwords.escape(ref)
          file_args = files.map { |f| Shellwords.escape(f) }.join(" ")
          "upload #{target} #{file_args}".strip
        when "dialog"
          response    = opts[:response]    || opts["response"]    || "accept"
          prompt_text = opts[:prompt_text] || opts["prompt_text"]
          if response.to_s == "dismiss"
            "dialog dismiss"
          elsif prompt_text
            "dialog accept #{Shellwords.escape(prompt_text)}"
          else
            "dialog accept"
          end
        when "console"
          "console"
        when "status"
          # agent-browser has no explicit status — check if the daemon is alive via version
          "--version"
        when "start"
          # Launching the daemon is implicit; use a no-op snapshot to warm up
          "snapshot -i"
        when "stop"
          "close"
        else
          # Unknown action — pass through as raw command for forward-compatibility
          action.to_s
        end
      end

      # Builds "snapshot [-i] [-C] [-c] [-d N] [-s SEL]" from options.
      private def build_snapshot_command(opts)
        parts = ["snapshot"]
        parts << "-i" if opts[:interactive] || opts["interactive"]
        parts << "-C" if opts[:cursor]      || opts["cursor"]
        parts << "-c" if opts[:compact]     || opts["compact"]

        depth = opts[:depth] || opts["depth"]
        parts += ["-d", depth.to_s] if depth

        selector = opts[:selector] || opts["selector"]
        parts += ["-s", Shellwords.escape(selector)] if selector && !selector.empty?

        parts.join(" ")
      end

      # Builds an interaction command ("click @e1", "fill @e2 'text'", etc.)
      # from the act opts hash.
      private def build_act_command(opts)
        kind      = (opts[:kind]     || opts["kind"]     || "click").to_s
        ref       = opts[:ref]       || opts["ref"]
        selector  = opts[:selector]  || opts["selector"]
        target    = ref && !ref.empty? ? ref : selector.to_s

        case kind
        when "click"
          double = opts[:double_click] || opts["double_click"]
          double ? "dblclick #{target}" : "click #{target}"
        when "dblclick"
          "dblclick #{target}"
        when "type"
          text = opts[:text] || opts["text"] || ""
          "type #{target} #{Shellwords.escape(text)}"
        when "fill"
          text = opts[:text] || opts["text"] || ""
          "fill #{target} #{Shellwords.escape(text)}"
        when "press"
          key = opts[:key] || opts["key"] || "Enter"
          "press #{Shellwords.escape(key)}"
        when "hover"
          "hover #{target}"
        when "check"
          "check #{target}"
        when "uncheck"
          "uncheck #{target}"
        when "select"
          values = Array(opts[:values] || opts["values"] || [])
          "select #{target} #{values.map { |v| Shellwords.escape(v) }.join(' ')}".strip
        when "drag"
          target_ref = opts[:target_ref] || opts["target_ref"] || ""
          "drag #{target} #{target_ref}"
        when "scroll"
          direction = opts[:direction] || opts["direction"] || "down"
          amount    = opts[:amount]    || opts["amount"]
          amount ? "scroll #{direction} #{amount}" : "scroll #{direction}"
        when "scrollintoview"
          "scrollintoview #{target}"
        when "wait"
          ms         = opts[:ms]         || opts["ms"]
          load_state = opts[:load_state] || opts["load_state"]
          wait_sel   = opts[:selector]   || opts["selector"]
          if ms
            "wait #{ms}"
          elsif load_state
            "wait --load #{Shellwords.escape(load_state)}"
          elsif wait_sel && !wait_sel.empty?
            "wait #{Shellwords.escape(wait_sel)}"
          else
            "wait 1000"
          end
        when "evaluate"
          js = opts[:js] || opts["js"] || ""
          "eval #{Shellwords.escape(js)}"
        when "close"
          "close"
        else
          # Unknown kind — pass through
          "#{kind} #{target}".strip
        end
      end

      # Builds the screenshot command string.
      private def build_screenshot_command(opts)
        parts = ["screenshot"]
        format    = opts[:format]    || opts["format"]    || "jpeg"
        quality   = opts[:quality]   || opts["quality"]   || 50
        full_page = opts[:full_page] || opts["full_page"]
        path      = opts[:path]      || opts["path"]

        parts += ["--screenshot-format", format]
        parts += ["--screenshot-quality", quality.to_s] if format.to_s == "jpeg"
        parts << "--full"  if full_page
        parts << Shellwords.escape(path) if path && !path.empty?

        parts.join(" ")
      end

      # -----------------------------------------------------------------------
      # Real-browser connection — two-stage discovery
      # -----------------------------------------------------------------------

      # Returns a CDP port number for the user's default Chromium browser, or nil.
      #
      # We exclusively use the browser's own DevToolsActivePort file, which
      # Chrome/Edge 144+ writes to <userDataDir> after the user allows remote
      # debugging. This approach is immune to other Chromium processes that may
      # be running on well-known ports (e.g. a dev Chrome with --remote-debugging-port=9222).
      #
      # Stage 1 — read DevToolsActivePort (already allowed, normal path)
      # Stage 2 — trigger the attach consent dialog, then poll for the file
      # Returns a notice string to include in the sandbox-fallback result, explaining
      # why we couldn't connect to the user's real browser.
      # Returns nil when the default browser IS Chromium and already connected.
      private def sandbox_fallback_notice(browser_info)
        if browser_info.nil?
          # Could not detect any Chromium-based browser at all.
          "⚠️  No Chromium-based browser found on this system. " \
          "Using a sandboxed browser instead. " \
          "For best results, please install Google Chrome, Microsoft Edge, or Brave."

        elsif browser_info[:default_is_chromium] == false
          # A Chromium browser was found as fallback, but the OS default is not Chromium.
          fallback_kind = browser_info[:kind].to_s.capitalize
          "⚠️  Your default browser is not Chromium-based, so it cannot be controlled by the agent. " \
          "Using #{fallback_kind} (found on this system) in sandboxed mode instead. " \
          "For the best experience, set Chrome, Edge, or Brave as your default browser."

        end
        # Returns nil implicitly when the browser is Chromium and CDP is reachable.
      end

      # Returns a CDP port or nil.
      #
      # Stage 1 — DevToolsActivePort file exists AND HTTP /json/version returns 200.
      #           Fast-path: the user's browser is already running with CDP enabled
      #           (e.g. launched via edge://inspect/#remote-debugging previously).
      #           We connect directly — zero disruption to the user's session.
      #
      # Stage 2 — No reachable CDP port. We spawn a brand-new, isolated browser
      #           instance with --remote-debugging-port=0 in a temporary user-data-dir.
      #           This approach:
      #             • Never touches the user's running browser or their open tabs
      #             • Completely bypasses the approval-mode consent dialog (which only
      #               appears for *attach* connections, not self-debugged launches)
      #             • Works even when the user's browser is not running at all
      #           The new instance starts headless in the background. The agent's
      #           commands run inside it, isolated from the user's real profile.
      #
      # Returns nil when CDP cannot be established (unsupported platform, browser
      # binary not found, or spawn timed out).
      private def resolve_user_browser_cdp_port(info = nil)
        info ||= ChromiumDetector.detect
        return nil unless info

        # Stage 1: DevToolsActivePort file exists AND CDP HTTP is fully ready (200 OK).
        port = read_dev_tools_port_once(info[:user_data_dir])
        if port && cdp_port_alive?(port)
          return port
        end

        # Stage 2: spawn a new browser instance with CDP enabled, reusing the
        # user's real user-data-dir so login state and cookies are preserved.
        spawn_debugging_browser(info[:kind], info[:user_data_dir])
      end

      # Returns true if the CDP endpoint at the given port is fully ready —
      # i.e. GET /json/version returns HTTP 200 with JSON content.
      #
      # Edge in approval-mode listens on TCP but returns HTTP 404 until the user
      # clicks "Allow" in the consent dialog. TCP-only probes cannot distinguish
      # between "ready" and "waiting for approval", so we use HTTP here.
      private def cdp_port_alive?(port)
        uri = URI("http://127.0.0.1:#{port}/json/version")
        res = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) do |http|
          http.get(uri.path)
        end
        res.is_a?(Net::HTTPOK) && !res.body.to_s.empty?
      rescue StandardError
        false
      end


      # Read DevToolsActivePort immediately — no waiting.
      # Returns port Integer or nil.
      private def read_dev_tools_port_once(user_data_dir)
        port_file = File.join(user_data_dir, "DevToolsActivePort")
        return nil unless File.exist?(port_file)

        content = File.read(port_file).strip
        port    = content.lines.first&.strip
        (port =~ /\A\d+\z/ && port.to_i > 0) ? port.to_i : nil
      rescue StandardError
        nil
      end

      # Poll for DevToolsActivePort up to `wait_secs` seconds.
      private def read_dev_tools_port(user_data_dir, wait_secs)
        deadline = Time.now + wait_secs
        loop do
          port = read_dev_tools_port_once(user_data_dir)
          return port if port
          break if Time.now >= deadline
          sleep DEV_TOOLS_PORT_POLL_INTERVAL
        end
        nil
      end

      # Returns true if the browser's Local State indicates the user has enabled
      # remote debugging via the inspect page (devtools.remote_debugging.user-enabled).
      #
      # When this pref is true, the browser starts the CDP server automatically
      # on launch (approval-mode). When false, it does nothing until the user
      # ticks the checkbox on the inspect page.
      #
      # Falls back to false if the file cannot be read or parsed — safer to
      # assume setup is needed than to wait too short.
      private def cdp_user_enabled?(user_data_dir)
        local_state_path = File.join(user_data_dir, "Local State")
        return false unless File.exist?(local_state_path)

        data = JSON.parse(File.read(local_state_path))
        data.dig("devtools", "remote_debugging", "user-enabled") == true
      rescue StandardError
        false
      end

      # Open the browser's inspect page to trigger the "Allow remote debugging?"
      # consent dialog (Chrome/Edge 144+ feature).
      # MacOS application names for each browser kind (used with `open -a`)
      MAC_BROWSER_APP_NAMES = {
        chrome:   "Google Chrome",
        edge:     "Microsoft Edge",
        brave:    "Brave Browser",
        chromium: "Chromium",
      }.freeze

      # Internal URL schemes for the DevTools inspect page
      CDP_INSPECT_SCHEMES = {
        chrome:   "chrome",
        edge:     "edge",
        brave:    "brave",
        chromium: "chrome",
      }.freeze

      # macOS binary paths for each browser kind — used to launch a new debugging
      # instance with --remote-debugging-port=0 directly (not via `open -a`, which
      # doesn't forward flags to an already-running browser process).
      MAC_BROWSER_EXECUTABLES = {
        chrome:   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        edge:     "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        brave:    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        chromium: "/Applications/Chromium.app/Contents/MacOS/Chromium",
      }.freeze

      # Spawn a new browser instance with --remote-debugging-port=0, reusing the
      # user's real user-data-dir (so cookies and login state are fully preserved).
      #
      # Chromium prevents two processes from sharing the same user-data-dir via
      # three symlink "Singleton" files (SingletonLock, SingletonCookie,
      # SingletonSocket). We remove those files before launching so the new
      # instance treats the directory as unclaimed. The original browser process
      # (if running) is left completely undisturbed — the user's tabs stay open.
      #
      # The browser writes the chosen port to DevToolsActivePort in the data dir
      # as soon as its CDP server is ready. We poll for that file and do an HTTP
      # health-check before returning.
      #
      # Returns the CDP port Integer on success, or nil on failure.
      private def spawn_debugging_browser(browser_kind, user_data_dir)
        return nil unless RUBY_PLATFORM.include?("darwin")

        exe = MAC_BROWSER_EXECUTABLES[browser_kind]
        exe = File.expand_path(exe)
        return nil unless exe && File.executable?(exe)

        # Remove Chromium's singleton lock files so the new instance can claim
        # the directory without conflicting with the already-running browser.
        %w[SingletonLock SingletonCookie SingletonSocket].each do |f|
          File.delete(File.join(user_data_dir, f)) rescue nil
        end

        # Remove stale port file so we can detect the fresh one cleanly.
        File.delete(File.join(user_data_dir, "DevToolsActivePort")) rescue nil

        # Launch directly (not via `open -a`) so flags reach the new process.
        # Stdout/stderr go to /dev/null to avoid polluting agent output.
        Process.spawn(
          exe,
          "--remote-debugging-port=0",
          "--user-data-dir=#{user_data_dir}",
          "--no-first-run",
          [:out, :err] => File::NULL
        )
        # Intentionally no Process.wait — browser must stay running.

        # Poll DevToolsActivePort, then HTTP-verify CDP is truly ready.
        deadline = Time.now + DEV_TOOLS_PORT_WAIT_SECS_SHORT
        loop do
          port = read_dev_tools_port_once(user_data_dir)
          return port if port && cdp_port_alive?(port)
          break if Time.now >= deadline
          sleep DEV_TOOLS_PORT_POLL_INTERVAL
        end

        nil
      end

      # -----------------------------------------------------------------------
      # Command building
      # -----------------------------------------------------------------------

      private def build_command(command, cdp_port: nil, session_name: nil, headed: true)
        parts = [AGENT_BROWSER_BIN]
        if cdp_port
          # Connect to user's real browser via CDP — no session-name, no --headed flag
          parts += ["--cdp", cdp_port.to_s]
        else
          parts << "--headed" if headed
          parts += ["--session-name", Shellwords.escape(session_name)] if session_name
        end
        parts << command
        parts.join(" ")
      end

      # -----------------------------------------------------------------------
      # Error detection helpers
      # -----------------------------------------------------------------------

      private def user_browser_connect_error?(result)
        output = "#{result[:stderr]}#{result[:stdout]}"
        # Typical messages when the browser isn't reachable or the CDP port is gone
        output.match?(/ECONNREFUSED|ECONNRESET|net::ERR|connect.*refused|Cannot connect|not.*running|Failed to connect/i)
      end

      private def session_closed_error?(result)
        output = "#{result[:stderr]}#{result[:stdout]}"
        output.include?("has been close") || output.include?("has been closed")
      end

      # -----------------------------------------------------------------------
      # agent-browser availability
      # -----------------------------------------------------------------------

      private def agent_browser_ready?
        agent_browser_installed? && !agent_browser_outdated?
      end

      private def not_ready_response
        {
          error: "agent-browser not ready",
          instructions: "Tell the user that browser automation is not set up yet, and ask them to run `/onboard browser` to complete the setup."
        }
      end

      private def agent_browser_installed?
        result = Shell.new.execute(command: "which #{AGENT_BROWSER_BIN}")
        result[:success] && !result[:stdout].to_s.strip.empty?
      end

      private def agent_browser_outdated?
        result  = Shell.new.execute(command: "#{AGENT_BROWSER_BIN} --version")
        version = result[:stdout].to_s.strip.split.last
        return false if version.nil? || version.empty?
        Gem::Version.new(version) < Gem::Version.new(MIN_AGENT_BROWSER_VERSION)
      rescue StandardError
        false
      end

      # -----------------------------------------------------------------------
      # Output formatting helpers
      # -----------------------------------------------------------------------

      # Normalises the raw Shell result into the hash format used internally
      private def format_result_hash(result)
        result
      end

      # Strip noise from snapshot output to reduce token usage.
      #
      # Removes:
      #   - "- /url: ..." lines         — LLM uses [ref=eN], not URLs
      #   - "- /placeholder: ..." lines  — already shown inline in textbox label
      #   - bare "- img" lines with no alt text — zero information
      private def compress_snapshot(output)
        return output if output.empty?

        lines    = output.lines
        orig     = lines.size
        filtered = lines.reject do |line|
          s = line.strip
          s.start_with?("- /url:", "/url:", "- /placeholder:", "/placeholder:") ||
            s == "- img" || s.match?(/\A-\s+img\s*\z/)
        end

        removed = orig - filtered.size
        filtered << "\n[snapshot compressed: #{removed} /url, /placeholder, empty-img lines removed]\n" if removed > 0
        filtered.join
      end

      private def command_name_for_temp(command)
        first_word = (command || "").strip.split(/\s+/).first
        File.basename(first_word.to_s, ".*")
      end

      private def truncate_and_save(output, max_chars, _label, command_name)
        return { content: "", temp_file: nil } if output.empty?
        return { content: output, temp_file: nil } if output.length <= max_chars

        lines = output.lines
        return { content: output, temp_file: nil } if lines.length <= 2

        safe_name = command_name.gsub(/[^\w\-.]/, "_")[0...50]
        temp_dir  = Dir.mktmpdir
        temp_file = File.join(temp_dir, "browser_#{safe_name}_#{Time.now.strftime("%Y%m%d_%H%M%S")}.output")
        File.write(temp_file, output)

        available  = max_chars - 200
        first_part = []
        accumulated = 0
        lines.each do |line|
          break if accumulated + line.length > available
          first_part << line
          accumulated += line.length
        end

        notice = "\n\n... [Output truncated: showing #{first_part.size} of #{lines.size} lines, full: #{temp_file} (use grep to search)] ...\n"
        { content: first_part.join + notice, temp_file: temp_file }
      end
    end
  end
end
