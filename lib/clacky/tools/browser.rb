# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "tmpdir"
require "shellwords"
require "yaml"
require "base64"
require "fileutils"
require "securerandom"
require_relative "base"

module Clacky
  module Tools
    # Browser tool — controls the user's real Chromium-based browser (Chrome 146+)
    # via the Chrome DevTools MCP server (chrome-devtools-mcp).
    #
    # Architecture: uses the existing-session driver (Chrome MCP).
    #   chrome-devtools-mcp --autoConnect --experimentalStructuredContent
    #       --experimental-page-id-routing
    #
    # Communication: MCP stdio JSON-RPC 2.0 over a *persistent* (daemon) process.
    # The MCP server process is started once, kept alive across all tool calls,
    # and only restarted when the process dies unexpectedly.
    #
    # pageId is intentionally NOT passed to most MCP calls — the MCP server
    # maintains its own selected page state. Only focus/close actions need pageId.
    # When the selected page has been closed, mcp_call automatically retries once.
    class Browser < Base
      self.tool_name = "browser"
      self.tool_description = <<~DESC.strip
        Drive the user's real Chrome for web automation. Prefer web_fetch for read-only pages.
        Actions: open | navigate | snapshot | act | screenshot | tabs | focus | close | status
        Workflow: open → snapshot(interactive:true) → act(ref=...). New tab from `open` is auto-selected; only use `focus` to switch back to a previously-opened tab.
        snapshot: returns hierarchical a11y tree truncated to ~8KB. Use query="text" to seek, or offset=N to page.
        act kinds: click | dblclick | type | fill | press | hover | scroll | drag | select | wait | evaluate | click_at
        evaluate: `js` is a JS expression, e.g. "document.title". For multi-line / async logic use an IIFE: "(async () => { const r = await fetch(...); return r.status })()". Result is JSON-encoded.
        screenshot: expensive — pass `ref` to capture one element instead of the whole page.
      DESC
      self.tool_category = "web"
      self.tool_parameters = {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: %w[snapshot act open navigate tabs focus close screenshot status]
          },
          kind: {
            type: "string",
            enum: %w[click dblclick type fill press hover drag select scroll wait evaluate click_at],
            description: "act: interaction kind"
          },
          ref:         { type: "string",  description: "element ref from snapshot (e.g. 'e1')" },
          text:        { type: "string",  description: "act type/fill text" },
          key:         { type: "string",  description: "act press key (e.g. 'Enter')" },
          direction:   { type: "string",  enum: %w[up down left right], description: "act scroll" },
          amount:      { type: "integer", description: "act scroll pixels (default 300)" },
          ms:          { type: "integer", description: "act wait ms" },
          selector:    { type: "string",  description: "act wait: text or CSS selector" },
          js:          { type: "string",  description: "act evaluate: JS expression (use IIFE for multi-line/async)" },
          target_ref:  { type: "string",  description: "act drag destination ref" },
          values:      { type: "array",   items: { type: "string" }, description: "act select options" },
          x:           { type: "number",  description: "click_at x px" },
          y:           { type: "number",  description: "click_at y px" },
          url:         { type: "string",  description: "open/navigate URL" },
          target_id:   { type: "string",  description: "focus/close tab id" },
          interactive: { type: "boolean", description: "snapshot: only interactive elements" },
          compact:     { type: "boolean", description: "snapshot: drop empty containers" },
          depth:       { type: "integer", description: "snapshot: max tree depth" },
          query:       { type: "string",  description: "snapshot: return window around first match" },
          offset:      { type: "integer", description: "snapshot: skip N lines (paging)" },
          full_page:   { type: "boolean", description: "screenshot: full page" }
        },
        required: ["action"]
      }

      MIN_CHROME_MAJOR      = 146
      MCP_HANDSHAKE_TIMEOUT = 10
      MCP_CALL_TIMEOUT      = 60
      MIN_NODE_MAJOR        = 20
      MAX_SNAPSHOT_CHARS    = 8000
      MAX_LLM_OUTPUT_CHARS  = 6000
      SNAPSHOT_QUERY_WINDOW = 60   # lines around a query hit
      # Errors that mean "the selected/active page is gone" — auto-retry once.
      RETRYABLE_PAGE_ERRORS = [
        "selected page has been closed",
        "No page found",
        "no active page",
        "Target closed",
        "page is detached"
      ].freeze

      def execute(action:, profile: nil, working_dir: nil, **opts)
        bypass = action.to_s == "status" ||
                 (action.to_s == "act" && (opts[:kind] || opts["kind"]).to_s == "evaluate")
        unless bypass
          return browser_not_setup_error unless File.exist?(BROWSER_CONFIG_PATH)
          return browser_disabled_error  unless browser_enabled?
        end
        execute_user_browser(action, opts)
      rescue StandardError => e
        { error: classify_browser_error(e) }
      end

      def format_call(args)
        action = args[:action] || args["action"] || "browser"
        "browser(#{action})"
      end

      def format_result(result)
        return "[Error] #{result[:error].to_s[0..80]}" if result[:error]
        return "[OK] #{result[:output].to_s.lines.size} lines" if result[:output]
        "[OK] Done"
      end

      def format_result_for_llm(result)
        return result if result[:error]

        action = result[:action].to_s

        if action == "screenshot" && result[:image_data]
          mime_type       = result[:mime_type] || "image/png"
          image_data      = result[:image_data]
          original_path   = result[:original_path]
          compressed_path = result[:compressed_path]

          text = "Screenshot captured."
          if original_path || compressed_path
            text += "\n- Original (full resolution): #{original_path || 'unavailable'}" \
                    "\n- Compressed (800px, sent to AI): #{compressed_path || 'unavailable'}"
          end

          return {
            content_string: text,
            image_inject: {
              mime_type: mime_type,
              base64_data: image_data,
              path: compressed_path || original_path
            }
          }
        end

        output = result[:output].to_s
        output = compress_snapshot(output) if action == "snapshot"
        max_chars = action == "snapshot" ? MAX_SNAPSHOT_CHARS : MAX_LLM_OUTPUT_CHARS

        {
          action:  action,
          success: result[:success],
          stdout:  truncate_output(output, max_chars),
          profile: result[:profile]
        }.compact
      end


      BROWSER_CONFIG_PATH = File.expand_path("~/.clacky/browser.yml").freeze

      BROWSER_DIAGNOSIS_HINT = <<~HINT.strip.freeze
        Inform the user and ask if they'd like to run a diagnosis.
        If yes, invoke the browser-setup skill with subcommand "doctor".
      HINT

      # Cause 1+2: Chrome not running, or Remote Debugging disabled (MCP can't distinguish them)
      BROWSER_NOT_CONNECTED_HINT = <<~HINT.strip.freeze
        Chrome is not reachable. Possible causes:
        1. Chrome is not running — ask the user to open Chrome.
        2. Remote Debugging is disabled — enable via chrome://inspect/#remote-debugging.
      HINT

      # Cause 3: MCP daemon crashed or failed to start
      BROWSER_DAEMON_HINT = <<~HINT.strip.freeze
        The browser MCP daemon crashed or failed to start. It may recover automatically on the next action.
        If it keeps failing, ask the user to restart Clacky.
      HINT

      # Cause 4: Chrome long-session unresponsiveness
      BROWSER_RESTART_HINT = <<~HINT.strip.freeze
        Chrome has become unresponsive. This often happens after Chrome has been running for a long time.
        Ask the user to restart Chrome, then retry the action.
      HINT

      # Classify a browser error and return an appropriate message for the AI.
      # Only Chrome connectivity errors (causes 1-4) get a specific hint + diagnosis offer.
      # MCP business errors (wrong params, stale element, page closed, etc.) pass through as-is.
      private def classify_browser_error(e)
        msg = e.message.to_s

        # Cause 4: Chrome unresponsive after long session (timed out waiting for MCP response)
        if msg.include?("timed out after")
          return "Browser error: #{msg}\n\n#{BROWSER_RESTART_HINT}\n\n#{BROWSER_DIAGNOSIS_HINT}"
        end

        # Cause 1+2: Chrome not running or Remote Debugging disabled
        if msg.include?("Could not connect to Chrome")
          return "Browser error: #{msg}\n\n#{BROWSER_NOT_CONNECTED_HINT}\n\n#{BROWSER_DIAGNOSIS_HINT}"
        end

        # Cause 3: MCP daemon crashed or handshake failed
        if msg.include?("handshake timed out") || msg.include?("Chrome MCP tool") || msg.include?("Chrome MCP initialize")
          return "Browser error: #{msg}\n\n#{BROWSER_DAEMON_HINT}\n\n#{BROWSER_DIAGNOSIS_HINT}"
        end

        # All other errors: MCP business errors, element/page errors — AI can self-correct.
        "Browser error: #{msg}"
      end

      private def browser_enabled?
        config = YAMLCompat.safe_load(File.read(BROWSER_CONFIG_PATH), permitted_classes: [Date, Time, Symbol])
        config.is_a?(Hash) && config["enabled"] == true
      end

      private def browser_not_setup_error
        {
          error: <<~MSG
            The browser tool is not configured. This tool call has been rejected to protect user experience.

            Ask the user if they'd like to set up the browser, then invoke the browser-setup skill to guide them through the setup. Retry this tool call after setup is complete.
          MSG
        }
      end

      private def browser_disabled_error
        {
          error: <<~MSG
            The browser tool is disabled by the user. This tool call has been rejected.

            Inform the user that they have disabled the browser tool. They can re-enable it from settings or by running "/browser-setup".
          MSG
        }
      end

      # -----------------------------------------------------------------------
      # Action dispatch
      # -----------------------------------------------------------------------

      private def execute_user_browser(action, opts)

        case action.to_s
        when "tabs"
          pages = extract_pages(mcp_call("list_pages"))
          { action: "tabs", success: true, profile: "user", output: format_tabs(pages), tabs: pages }

        when "snapshot"
          raw  = mcp_call("take_snapshot", with_page({}))
          text = build_ai_snapshot(extract_snapshot(raw),
                                   interactive: opts[:interactive] || opts["interactive"],
                                   compact:     opts[:compact]     || opts["compact"],
                                   max_depth:   opts[:depth]       || opts["depth"])
          text = apply_snapshot_window(text,
                                       query:  opts[:query]  || opts["query"],
                                       offset: opts[:offset] || opts["offset"])
          { action: "snapshot", success: true, profile: "user", output: text }

        when "open"
          url = require_url(opts)
          return url if url.is_a?(Hash)
          invalidate_page_cache!
          mcp_call("new_page", { url: url })
          wait_for_page_ready
          { action: "open", success: true, profile: "user", url: url, output: "Opened: #{url}" }

        when "navigate"
          url = require_url(opts)
          return url if url.is_a?(Hash)
          invalidate_page_cache!
          mcp_call("navigate_page", with_page({ type: "url", url: url }))
          wait_for_page_ready
          { action: "navigate", success: true, profile: "user", url: url, output: "Navigated to: #{url}" }

        when "focus"
          target_id = opts[:target_id] || opts["target_id"]
          return { error: "target_id is required for focus. Use action=tabs to list open tabs." } if target_id.nil? || target_id.to_s.empty?
          invalidate_page_cache!
          mcp_call("select_page", { pageId: target_id.to_i, bringToFront: true })
          @page_id_cache = target_id.to_i
          { action: "focus", success: true, profile: "user", output: "Focused tab #{target_id}" }

        when "close"
          target_id = opts[:target_id] || opts["target_id"]
          return { error: "target_id is required for close. Use action=tabs to list open tabs." } if target_id.nil? || target_id.to_s.empty?
          invalidate_page_cache!
          mcp_call("close_page", { pageId: target_id.to_i })
          { action: "close", success: true, profile: "user", output: "Closed tab #{target_id}" }

        when "act"
          do_user_act(opts)

        when "screenshot"
          do_user_screenshot(opts)

        when "status"
          pages = extract_pages(mcp_call("list_pages"))
          { action: "status", success: true, profile: "user",
            output: "Browser running. #{pages.size} tab(s) open.", tabs: pages }

        else
          { error: "Action '#{action}' is not supported." }
        end
      end

      private def do_user_act(opts)
        kind = (opts[:kind] || opts["kind"] || "click").to_s
        ref  = opts[:ref]   || opts["ref"]

        # Page-scoped MCP calls all benefit from an explicit pageId. We pass it
        # transparently via with_page so the AI never has to think about it.
        case kind
        when "click", "dblclick"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          args = { uid: uid }
          args[:dblClick] = true if kind == "dblclick"
          mcp_call("click", with_page(args))

        when "fill", "type"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          mcp_call("fill", with_page({ uid: uid, value: opts[:text] || opts["text"] || "" }))

        when "press"
          mcp_call("press_key", with_page({ key: opts[:key] || opts["key"] || "Enter" }))

        when "hover"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          mcp_call("hover", with_page({ uid: uid }))

        when "drag"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          mcp_call("drag", with_page({ from_uid: uid, to_uid: opts[:target_ref] || opts["target_ref"] || "" }))

        when "select"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          values = Array(opts[:values] || opts["values"] || [])
          mcp_call("fill", with_page({ uid: uid, value: values.first.to_s }))

        when "scroll"
          direction = opts[:direction] || opts["direction"] || "down"
          amount    = (opts[:amount]   || opts["amount"]   || 300).to_i
          dx = case direction; when "right" then amount; when "left" then -amount; else 0; end
          dy = case direction; when "down"  then amount; when "up"   then -amount; else 0; end
          mcp_call("evaluate_script",
                   with_page({ function: "() => { window.scrollBy(#{dx}, #{dy}) }" }))

        when "wait"
          ms  = opts[:ms]       || opts["ms"]
          sel = opts[:selector] || opts["selector"]
          if ms
            sleep(ms.to_i / 1000.0)
            return { action: "act", success: true, profile: "user", output: "Waited #{ms}ms" }
          elsif sel
            mcp_call("wait_for", with_page({ text: [sel] }))
          else
            sleep(1)
          end

        when "evaluate"
          js = (opts[:js] || opts["js"] || "").to_s
          fn = build_evaluate_function(js)
          result = mcp_call("evaluate_script", with_page({ function: fn }))
          return { action: "act", success: true, profile: "user", output: extract_message(result).to_s }

        when "click_at"
          x = opts[:x] || opts["x"]
          y = opts[:y] || opts["y"]
          return { error: "click_at requires x and y coordinates" } unless x && y
          result = mcp_call("click_at", with_page({ x: x.to_f, y: y.to_f }))
          return { action: "act", success: true, profile: "user", output: extract_message(result).to_s }

        else
          return { error: "Unknown act kind: #{kind}" }
        end

        { action: "act", success: true, profile: "user", output: "#{kind} completed." }
      end

      # Merge pageId into MCP args when we know the current page. Safe no-op
      # if the cache is empty — the MCP server then falls back to its own
      # selected-page state, matching the old behaviour.
      private def with_page(args)
        pid = current_page_id
        pid ? args.merge(pageId: pid) : args
      end

      private def build_evaluate_function(js)
        body = js.to_s.strip
        return "() => {}" if body.empty?
        "() => (#{body})"
      end

      SCREENSHOT_MAX_WIDTH        = 800
      SCREENSHOT_MAX_BASE64_BYTES = 150_000

      private def do_user_screenshot(opts)
        full_page = opts[:full_page] || opts["full_page"] || false
        uid       = opts[:ref]       || opts["ref"]

        call_args = { format: "png", fullPage: full_page }
        call_args[:uid] = uid if uid
        result = mcp_call("take_screenshot", with_page(call_args))

        image_block = Array(result["content"]).find { |b| b.is_a?(Hash) && b["type"] == "image" }

        unless image_block
          text = extract_text_content(result)
          return { action: "screenshot", success: true, profile: "user",
                   output: text.empty? ? "Screenshot captured." : text }
        end

        # Save original (full-resolution) PNG to disk before any downscaling
        original_path = save_screenshot_to_disk(image_block["data"], suffix: "original")

        image_data = png_downscale_base64(image_block["data"], SCREENSHOT_MAX_WIDTH)

        if image_data.bytesize > SCREENSHOT_MAX_BASE64_BYTES
          size_kb = image_data.bytesize / 1024
          return { action: "screenshot", success: false, profile: "user",
                   output: "Screenshot too large after resize (#{size_kb}KB). Use action=snapshot instead." }
        end

        # Save compressed (800px) PNG for AI reference
        compressed_path = save_screenshot_to_disk(image_data, suffix: "compressed")

        { action: "screenshot", success: true, profile: "user",
          image_data: image_data, mime_type: "image/png",
          original_path: original_path, compressed_path: compressed_path,
          output: "Screenshot captured." }
      end

      private def png_downscale_base64(b64, max_width)
        Clacky::Utils::FileProcessor.downscale_image_base64(
          b64, "image/png", max_width: max_width
        )
      end

      # Save a base64-encoded PNG screenshot to disk and return the file path.
      # suffix: "original" or "compressed" — embedded in filename for clarity.
      # Uses the same upload directory as other image files so the agent can
      # reference, read, or pass the path to other tools.
      private def save_screenshot_to_disk(base64_data, suffix: nil)
        upload_dir = File.join(Dir.tmpdir, "clacky-uploads")
        FileUtils.mkdir_p(upload_dir)
        ts       = Time.now.strftime("%Y%m%d_%H%M%S")
        hex      = SecureRandom.hex(4)
        label    = suffix ? "_#{suffix}" : ""
        filename = "screenshot_#{ts}_#{hex}#{label}.png"
        path     = File.join(upload_dir, filename)
        File.binwrite(path, Base64.strict_decode64(base64_data))
        path
      rescue => e
        Clacky::Logger.error("screenshot_save_failed", error: e.message)
        nil
      end

      # -----------------------------------------------------------------------
      # Chrome MCP
      # -----------------------------------------------------------------------

      # Delegate to BrowserManager. Auto-retries once on transient page-context errors
      # (closed/detached selected page, or "no active page" right after open).
      private def mcp_call(tool_name, arguments = {})
        Clacky::BrowserManager.instance.mcp_call(tool_name, arguments)
      rescue RuntimeError => e
        msg = e.message.to_s
        if RETRYABLE_PAGE_ERRORS.any? { |frag| msg.include?(frag) }
          # Try to recover by re-selecting the most recent page, then retry once.
          recovered = recover_selected_page
          if recovered
            @page_id_cache = nil
            return Clacky::BrowserManager.instance.mcp_call(tool_name, arguments)
          end
          raise RuntimeError, "The browser tab is no longer available. Use action=open to open a new tab, then retry."
        end
        raise
      end

      # Pick the currently selected page, or fall back to the most recent one,
      # and re-issue select_page so subsequent calls have a valid context.
      # Returns the chosen pageId, or nil if there are no pages at all.
      private def recover_selected_page
        list = Clacky::BrowserManager.instance.mcp_call("list_pages")
        pages = extract_pages(list)
        return nil if pages.empty?
        target = pages.find { |p| p[:selected] } || pages.last
        Clacky::BrowserManager.instance.mcp_call("select_page",
          { pageId: target[:id].to_i, bringToFront: false })
        target[:id].to_i
      rescue StandardError
        nil
      end

      # Cached lookup of the currently selected pageId. The MCP server tracks
      # selected state internally, but several tools/call paths drop it under
      # race conditions (tab just opened, focus mid-flight). Passing pageId
      # explicitly to every page-scoped call eliminates "No page found" flakes.
      # Cache is invalidated by retry path and by open/navigate/focus.
      private def current_page_id
        return @page_id_cache if @page_id_cache
        list = Clacky::BrowserManager.instance.mcp_call("list_pages")
        pages = extract_pages(list)
        sel = pages.find { |p| p[:selected] } || pages.last
        @page_id_cache = sel && sel[:id] && sel[:id].to_i
      rescue StandardError
        nil
      end

      private def invalidate_page_cache!
        @page_id_cache = nil
      end

      # After open/navigate, briefly poll until a selected page exists.
      # Avoids the classic race where the next act/snapshot fires before
      # chrome-devtools-mcp has registered the new tab.
      private def wait_for_page_ready(timeout: 1.5)
        deadline = Time.now + timeout
        while Time.now < deadline
          pid = current_page_id
          return pid if pid
          sleep 0.1
          invalidate_page_cache!
        end
        nil
      rescue StandardError
        nil
      end

      # -----------------------------------------------------------------------
      # MCP response extractors
      # -----------------------------------------------------------------------

      private def extract_pages(result)
        return [] unless result.is_a?(Hash)

        structured = result["structuredContent"]
        if structured.is_a?(Hash) && structured["pages"].is_a?(Array)
          return structured["pages"].map do |p|
            { id: p["id"], url: p["url"], selected: p["selected"] == true }
          end
        end

        parse_pages_from_text(extract_text_content(result))
      end

      private def extract_snapshot(result)
        return {} unless result.is_a?(Hash)

        structured = result["structuredContent"]
        return structured["snapshot"] if structured.is_a?(Hash) && structured["snapshot"].is_a?(Hash)

        begin
          JSON.parse(extract_text_content(result))
        rescue StandardError
          {}
        end
      end

      private def extract_message(result)
        return "" unless result.is_a?(Hash)

        structured = result["structuredContent"]
        return structured["message"].to_s if structured.is_a?(Hash) && structured["message"]

        extract_text_content(result)
      end

      private def extract_text_content(result)
        return "" unless result.is_a?(Hash)
        Array(result["content"]).filter_map do |entry|
          entry["text"] if entry.is_a?(Hash) && entry["text"].is_a?(String)
        end.join("\n")
      end

      private def parse_pages_from_text(text)
        text.each_line.filter_map do |line|
          m = line.match(/^\s*(\d+):\s+(.+?)(?:\s+\[(selected)\])?\s*$/i)
          next unless m
          { id: m[1].to_i, url: m[2].strip, selected: !m[3].nil? }
        end
      end

      private def format_tabs(pages)
        return "No open tabs." if pages.empty?
        pages.map { |p| "#{p[:id]}: #{p[:url]}#{p[:selected] ? ' [selected]' : ''}" }.join("\n")
      end

      # -----------------------------------------------------------------------
      # Snapshot rendering
      # -----------------------------------------------------------------------

      INTERACTIVE_ROLES = %w[
        button link textbox checkbox radio select combobox
        menuitem option tab switch searchbox spinbutton
        slider menuitemcheckbox menuitemradio
      ].freeze

      STRUCTURAL_ROLES = %w[
        generic none presentation group region section
      ].freeze

      CONTENT_ROLES = %w[
        heading paragraph text statictext image img
        listitem term definition
      ].freeze

      private def build_ai_snapshot(node, interactive: false, compact: false, max_depth: nil)
        return "" unless node.is_a?(Hash) && !node.empty?

        lines = []
        refs  = {}
        visit_node(node, 0, lines, refs, interactive: interactive, compact: compact, max_depth: max_depth)
        lines.join("\n")
      end

      private def visit_node(node, depth, lines, refs, interactive:, compact:, max_depth:)
        return if max_depth && depth > max_depth

        role = node["role"].to_s.downcase.strip
        role = "generic" if role.empty?
        name = node["name"].to_s.strip
        uid  = node["id"].to_s.strip
        val  = node["value"]
        desc = node["description"].to_s.strip

        render = true
        render = false if interactive && !INTERACTIVE_ROLES.include?(role)
        render = false if compact && STRUCTURAL_ROLES.include?(role) && name.empty?

        if render
          line = "#{" " * (depth * 2)}- #{role}"
          line += " \"#{escape_quoted(name)}\"" unless name.empty?

          if uid && !uid.empty? && (INTERACTIVE_ROLES.include?(role) ||
                                    (CONTENT_ROLES.include?(role) && !name.empty?))
            refs[uid] = { role: role, name: name }
            line += " [ref=#{uid}]"
          end

          line += " value=\"#{escape_quoted(val.to_s)}\"" unless val.nil? || val.to_s.empty?
          line += " description=\"#{escape_quoted(desc)}\"" unless desc.empty?
          lines << line
        end

        child_depth = render ? depth + 1 : depth
        Array(node["children"]).each do |child|
          visit_node(child, child_depth, lines, refs, interactive: interactive, compact: compact, max_depth: max_depth)
        end
      end

      private def escape_quoted(str)
        str.to_s.gsub("\\", "\\\\").gsub('"', '\\"')
      end

      # -----------------------------------------------------------------------
      # Parameter helpers
      # -----------------------------------------------------------------------

      private def require_url(opts)
        url = opts[:url] || opts["url"] || ""
        return { error: "url is required for this action" } if url.empty?
        url
      end

      private def require_ref(ref)
        return { error: "ref is required for this act kind (snapshot first to get refs)" } if ref.nil? || ref.to_s.empty?
        ref.to_s
      end

      # -----------------------------------------------------------------------
      # Output helpers
      # -----------------------------------------------------------------------

      # Apply optional `query` / `offset` to a freshly-built snapshot. When
      # `query` matches, return a window of SNAPSHOT_QUERY_WINDOW lines around
      # the first hit. When `offset` is given, drop the first N lines. Returns
      # the original text untouched when neither is provided. Both options let
      # the AI request just the slice it needs instead of the whole tree.
      private def apply_snapshot_window(text, query: nil, offset: nil)
        return text if (query.nil? || query.to_s.empty?) && (offset.nil? || offset.to_i <= 0)

        lines = text.lines
        total = lines.size

        if query && !query.to_s.empty?
          q = query.to_s
          idx = lines.index { |l| l.include?(q) }
          if idx.nil?
            return "[snapshot: no match for query=#{q.inspect} in #{total} lines]\n"
          end
          half  = SNAPSHOT_QUERY_WINDOW / 2
          start = [idx - half, 0].max
          stop  = [idx + half, total - 1].min
          window = lines[start..stop].join
          header = "[snapshot window: lines #{start + 1}-#{stop + 1} of #{total}, match at line #{idx + 1}]\n"
          return header + window
        end

        skip = offset.to_i
        return "[snapshot: offset #{skip} >= #{total} total lines]\n" if skip >= total
        header = "[snapshot offset: showing from line #{skip + 1} of #{total}]\n"
        header + lines[skip..-1].join
      end

      private def compress_snapshot(output)
        return output if output.empty?

        lines    = output.lines
        orig     = lines.size

        # Pass 1: drop pure noise lines.
        filtered = lines.reject do |line|
          s = line.strip
          s.start_with?("- /url:", "/url:", "- /placeholder:", "/placeholder:") ||
            s == "- img" || s.match?(/\A-\s+img\s*\z/) ||
            # statictext nodes that are just line numbers / single digits / bullets
            s.match?(/\A-\s+statictext\s+"\d{1,3}"\s*\z/) ||
            s.match?(/\A-\s+statictext\s+""\s*\z/) ||
            # an empty statictext placeholder ([ref=…] but no content) is also noise
            s.match?(/\A-\s+statictext\s*\z/)
        end

        # Pass 2: collapse runs of consecutive statictext lines at the same
        # indent into a single line, joining their quoted text with " / ".
        # Long form pages (article / docs) easily explode 500+ statictext nodes;
        # this is the single biggest token saver.
        collapsed = []
        run = nil  # { indent:, texts:, ref: }
        flush = lambda do
          if run
            head = "#{' ' * run[:indent]}- statictext \"#{run[:texts].join(' / ')}\""
            head += " [ref=#{run[:ref]}]" if run[:ref]
            collapsed << head + "\n"
            run = nil
          end
        end

        filtered.each do |line|
          m = line.match(/\A(\s*)-\s+statictext\s+"(.*?)"(?:\s+\[ref=([^\]]+)\])?\s*\z/)
          if m
            indent = m[1].length
            text   = m[2]
            ref    = m[3]
            if run && run[:indent] == indent && run[:ref].nil? && ref.nil?
              # merge text-only statictext runs (no refs) — keep refs separate so
              # the AI can still target individual elements.
              run[:texts] << text unless run[:texts].last == text  # cheap dedupe
            else
              flush.call
              run = { indent: indent, texts: [text], ref: ref }
            end
          else
            flush.call
            collapsed << line
          end
        end
        flush.call

        removed = orig - collapsed.size
        collapsed << "\n[snapshot compressed: #{removed} lines removed]\n" if removed > 0
        collapsed.join
      end

      private def truncate_output(output, max_chars)
        return output if output.length <= max_chars

        lines      = output.lines
        available  = max_chars - 200
        first_part = []
        acc        = 0
        lines.each do |line|
          break if acc + line.length > available
          first_part << line
          acc += line.length
        end
        hint = "\n... [truncated: #{first_part.size}/#{lines.size} lines shown — " \
               "rerun with query=\"keyword\" or offset=#{first_part.size} to see more] ...\n"
        first_part.join + hint
      end
    end
  end
end
