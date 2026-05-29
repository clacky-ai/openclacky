# frozen_string_literal: true

require "json"
require "monitor"

require_relative "transport"
require_relative "stdio_transport"
require_relative "http_transport"

module Clacky
  module Mcp
    # JSON-RPC 2.0 client for a single MCP server.
    #
    # Lifecycle: open transport on #start, send `initialize` handshake, then any
    # number of `tools/list` / `tools/call` requests, then #stop closes the
    # transport. Transport is selected by spec["type"]: "stdio" (default) or "http".
    class Client
      class McpError < StandardError; end
      TransportError = Mcp::Transport::TransportError
      class ProtocolError < McpError; end

      DEFAULT_TIMEOUT = 30
      INIT_TIMEOUT    = 15

      PROTOCOL_VERSION = "2024-11-05"

      attr_reader :name, :tools, :server_info, :started_at, :last_used_at

      # Build a Client from an mcp.json spec hash.
      # Recognized fields:
      #   stdio: command (required), args, env, cwd
      #   http:  type: "http", url (required), headers
      def self.from_spec(name, spec)
        type = (spec["type"] || (spec["url"] ? "http" : "stdio")).to_s
        case type
        when "stdio"
          new(
            name:    name,
            transport: StdioTransport.new(
              name:    name,
              command: spec["command"],
              args:    Array(spec["args"]),
              env:     spec["env"] || {},
              cwd:     spec["cwd"]
            )
          )
        when "http", "streamable-http"
          new(
            name:    name,
            transport: HttpTransport.new(
              name:    name,
              url:     spec["url"],
              headers: spec["headers"] || {}
            )
          )
        else
          raise McpError, "unsupported MCP transport type '#{type}' for server '#{name}'"
        end
      end

      def initialize(name:, transport: nil, command: nil, args: [], env: {}, cwd: nil)
        @name = name
        @transport = transport || StdioTransport.new(name: name, command: command, args: args, env: env, cwd: cwd)

        @pending = {}
        @next_id = 0
        @lock    = Monitor.new
        @started = false

        @tools       = []
        @server_info = nil
        @started_at  = nil
        @last_used_at = nil

        @transport.on_message do |msg|
          if msg["__transport_closed__"]
            @lock.synchronize do
              @pending.each_value { |q| q.push({ "error" => { "code" => -32000, "message" => "transport closed" } }) }
              @pending.clear
            end
            next
          end

          id = msg["id"]
          if id && (queue = @lock.synchronize { @pending.delete(id) })
            queue.push(msg)
          end
        end
      end

      def started?
        @started
      end

      def start
        already_started = false
        @lock.synchronize do
          if @started
            already_started = true
          else
            @transport.start
          end
        end
        return self if already_started

        handshake
        fetch_tools

        @lock.synchronize do
          @started = true
          @started_at = Time.now
          @last_used_at = @started_at
        end
        self
      end

      def stop
        @lock.synchronize do
          @transport.stop rescue nil
          @started = false
        end
      end

      def tool_definitions
        @tools.map do |t|
          {
            type: "function",
            function: {
              name: t["name"],
              description: t["description"].to_s,
              parameters: t["inputSchema"] || { type: "object", properties: {} }
            }
          }
        end
      end

      def call_tool(tool_name, arguments = {})
        ensure_started!
        @last_used_at = Time.now
        request("tools/call", { name: tool_name, arguments: arguments || {} })
      end

      def stderr_tail(bytes: 4096)
        @transport.stderr_tail(bytes: bytes)
      end

      private def ensure_started!
        raise TransportError, "MCP client '#{@name}' is not started" unless @started
        raise TransportError, "MCP server '#{@name}' transport closed" unless @transport.alive?
      end

      private def handshake
        result = request("initialize", {
          protocolVersion: PROTOCOL_VERSION,
          capabilities:    { tools: {} },
          clientInfo:      { name: "openclacky", version: Clacky::VERSION }
        }, timeout: INIT_TIMEOUT)

        @server_info = result["serverInfo"]
        notify("notifications/initialized")
      end

      private def fetch_tools
        result = request("tools/list", {})
        @tools = result["tools"] || []
      end

      private def request(method, params, timeout: DEFAULT_TIMEOUT)
        id = nil
        queue = Queue.new
        @lock.synchronize do
          id = (@next_id += 1)
          @pending[id] = queue
        end

        payload = { jsonrpc: "2.0", id: id, method: method, params: params }
        @transport.send_message(payload)

        msg = nil
        begin
          require "timeout"
          msg = Timeout.timeout(timeout) { queue.pop }
        rescue Timeout::Error
          msg = nil
        end

        if msg.nil?
          @lock.synchronize { @pending.delete(id) }
          raise TransportError, "MCP request '#{method}' to '#{@name}' timed out after #{timeout}s"
        end

        if (err = msg["error"])
          raise ProtocolError, "MCP server '#{@name}' error on #{method}: #{err["message"]} (code #{err["code"]})"
        end

        msg["result"] || {}
      end

      private def notify(method, params = {})
        @transport.send_message({ jsonrpc: "2.0", method: method, params: params })
      end
    end
  end
end
