# frozen_string_literal: true

require "yaml"

module Clacky
  # BrowserManager owns the chrome-devtools-mcp daemon lifecycle.
  #
  # It mirrors the ChannelManager pattern:
  #   - start   → read browser.yml; if configured, pre-warm the MCP daemon
  #   - stop    → kill the daemon
  #   - reload  → stop + re-read yml + start (called after browser-setup writes yml)
  #   - status  → { configured: bool, daemon_running: bool, chrome_version: String|nil }
  #
  # Browser tool (browser.rb) delegates daemon access here instead of using
  # class-level @@mcp_process variables directly.  BrowserManager holds the
  # single mutable state; the mutex lives here too.
  class BrowserManager
    BROWSER_CONFIG_PATH = File.expand_path("~/.clacky/browser.yml").freeze

    class << self
      def instance
        @instance ||= new
      end
    end

    def initialize
      @process  = nil   # { stdin:, stdout:, pid:, wait_thr: }
      @mutex    = Mutex.new
      @call_id  = 2     # 1 reserved for MCP initialize handshake
      @config   = {}    # last successfully read browser.yml content
    end

    # ---------------------------------------------------------------------------
    # Lifecycle
    # ---------------------------------------------------------------------------

    # Start the daemon if browser.yml marks the browser as configured.
    # Non-blocking — returns immediately (daemon spawn takes ~200ms in background).
    def start
      cfg = load_config
      unless cfg["configured"] == true
        Clacky::Logger.info("[BrowserManager] Not configured — skipping daemon start")
        return
      end

      @config = cfg
      Clacky::Logger.info("[BrowserManager] Browser configured, pre-warming MCP daemon...")
      Thread.new do
        Thread.current.name = "browser-manager-start"
        @mutex.synchronize { ensure_process! }
      rescue StandardError => e
        Clacky::Logger.warn("[BrowserManager] Pre-warm failed: #{e.message}")
      end
    end

    # Stop and clean up the daemon.
    def stop
      @mutex.synchronize { kill_process! }
      Clacky::Logger.info("[BrowserManager] Daemon stopped")
    end

    # Hot-reload: stop existing daemon, re-read yml, restart if configured.
    # Called by HttpServer after browser-setup writes a new browser.yml.
    def reload
      Clacky::Logger.info("[BrowserManager] Reloading...")
      @mutex.synchronize { kill_process! }

      cfg = load_config
      @config = cfg

      if cfg["configured"] == true
        Clacky::Logger.info("[BrowserManager] Configuration found, restarting daemon")
        Thread.new do
          Thread.current.name = "browser-manager-reload"
          @mutex.synchronize { ensure_process! }
        rescue StandardError => e
          Clacky::Logger.warn("[BrowserManager] Reload start failed: #{e.message}")
        end
      else
        Clacky::Logger.info("[BrowserManager] Not configured after reload — daemon not started")
      end
    end

    # Returns a status hash with real daemon liveness.
    # @return [Hash] { configured: bool, daemon_running: bool, chrome_version: String|nil }
    def status
      cfg = load_config
      configured = cfg["configured"] == true
      running    = @mutex.synchronize { process_alive? }
      {
        configured:     configured,
        daemon_running: running,
        chrome_version: cfg["chrome_version"]
      }
    end

    # ---------------------------------------------------------------------------
    # MCP call interface — used by Browser tool
    # ---------------------------------------------------------------------------

    # Execute a chrome-devtools-mcp tool call. Ensures daemon is running first.
    # Thread-safe via @mutex.
    # @param tool_name  [String]
    # @param arguments  [Hash]
    # @return [Hash] parsed MCP result
    # @raise [RuntimeError] on timeout or protocol error
    def mcp_call(tool_name, arguments = {})
      call_resp = nil

      @mutex.synchronize do
        ensure_process!

        call_id  = @call_id
        @call_id += 1

        msg = json_rpc("tools/call", { name: tool_name, arguments: arguments }, id: call_id)
        @process[:stdin].write(msg + "\n")
        @process[:stdin].flush

        call_resp = read_response(@process[:stdout], target_id: call_id,
                                  timeout: Clacky::Tools::Browser::MCP_CALL_TIMEOUT)

        unless call_resp
          kill_process!
          raise "Chrome MCP tools/call '#{tool_name}' timed out after #{Clacky::Tools::Browser::MCP_CALL_TIMEOUT}s"
        end

        if call_resp["error"]
          err = call_resp["error"]
          raise "Chrome MCP error: #{err.is_a?(Hash) ? err["message"] : err}"
        end

        result = call_resp["result"] || {}

        if result["isError"]
          text = extract_text_content(result)
          raise text.empty? ? "Chrome MCP tool '#{tool_name}' failed" : text
        end

        result
      end
    end

    # ---------------------------------------------------------------------------
    # Private
    # ---------------------------------------------------------------------------
    private

    def load_config
      return {} unless File.exist?(BROWSER_CONFIG_PATH)
      YAML.safe_load(File.read(BROWSER_CONFIG_PATH), permitted_classes: [Date, Time, Symbol]) || {}
    rescue StandardError => e
      Clacky::Logger.warn("[BrowserManager] Failed to read browser.yml: #{e.message}")
      {}
    end

    # Must be called inside @mutex
    def ensure_process!
      return if process_alive?

      cmd = Clacky::Tools::Browser.build_mcp_command
      stdin, stdout, stderr_io, wait_thr = Open3.popen3(*cmd)
      Thread.new { stderr_io.read rescue nil }

      # MCP handshake
      init_msg = json_rpc("initialize", {
        protocolVersion: "2024-11-05",
        capabilities:    {},
        clientInfo:      { name: "clacky", version: "1.0" }
      }, id: 1)

      notify_msg = JSON.generate({
        jsonrpc: "2.0",
        method:  "notifications/initialized",
        params:  {}
      })

      stdin.write(init_msg + "\n")
      stdin.flush

      init_resp = read_response(stdout, target_id: 1,
                                timeout: Clacky::Tools::Browser::MCP_HANDSHAKE_TIMEOUT)
      unless init_resp
        Process.kill("TERM", wait_thr.pid) rescue nil
        raise "Chrome MCP initialize handshake timed out"
      end

      stdin.write(notify_msg + "\n")
      stdin.flush

      @process = { stdin: stdin, stdout: stdout, pid: wait_thr.pid, wait_thr: wait_thr }
      @call_id = 2
      Clacky::Logger.info("[BrowserManager] MCP daemon started (pid=#{wait_thr.pid})")
    end

    # Must be called inside @mutex
    def process_alive?
      return false if @process.nil?

      Process.kill(0, @process[:pid])
      !@process[:stdin].closed? && !@process[:stdout].closed?
    rescue Errno::ESRCH, Errno::EPERM
      kill_process!
      false
    end

    # Must be called inside @mutex
    def kill_process!
      ps = @process
      return unless ps

      Process.kill("TERM", ps[:pid]) rescue nil
      ps[:stdin].close  rescue nil
      ps[:stdout].close rescue nil
      @process = nil
      Clacky::Logger.info("[BrowserManager] MCP daemon killed")
    end

    def json_rpc(method, params, id:)
      JSON.generate({ jsonrpc: "2.0", id: id, method: method, params: params })
    end

    def read_response(io, target_id:, timeout: 10)
      Timeout.timeout(timeout) do
        loop do
          line = io.gets
          break if line.nil?
          line = line.strip
          next if line.empty?
          begin
            msg = JSON.parse(line)
            return msg if msg.is_a?(Hash) && msg["id"] == target_id
          rescue JSON::ParserError
            next
          end
        end
        nil
      end
    rescue Timeout::Error
      nil
    end

    def extract_text_content(result)
      Array(result["content"])
        .select { |b| b.is_a?(Hash) && b["type"] == "text" }
        .map { |b| b["text"].to_s }
        .join("\n")
    end
  end
end
