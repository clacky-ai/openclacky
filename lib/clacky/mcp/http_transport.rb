# frozen_string_literal: true

require "json"
require "monitor"
require "net/http"
require "uri"
require "securerandom"

require_relative "transport"

module Clacky
  module Mcp
    # MCP streamable-http transport (spec 2025-03-26).
    #
    # One endpoint URL handles both client→server (POST) and server→client (SSE).
    # We POST every JSON-RPC message; the server may respond with either:
    #   - application/json   → single response, deliver immediately
    #   - text/event-stream  → one or more "data:" SSE events, each a JSON-RPC msg
    #
    # Session tracking: the server returns Mcp-Session-Id on the initialize
    # response; we echo it on every subsequent request.
    class HttpTransport < Transport
      DEFAULT_OPEN_TIMEOUT = 10
      DEFAULT_READ_TIMEOUT = 120

      def initialize(name:, url:, headers: {}, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
        @name = name
        @uri  = URI.parse(url)
        raise TransportError, "MCP server '#{name}' url is not http(s): #{url}" unless %w[http https].include?(@uri.scheme)

        @extra_headers = (headers || {}).transform_keys(&:to_s).transform_values(&:to_s)
        @open_timeout  = open_timeout
        @read_timeout  = read_timeout

        @session_id = nil
        @on_message = nil
        @lock = Monitor.new
        @alive = false
        @last_error = nil
      end

      def start
        @alive = true
        self
      end

      def stop
        @alive = false
      end

      def alive?
        @alive
      end

      def send_message(payload)
        raise TransportError, "transport stopped" unless @alive

        body = JSON.generate(payload)
        is_request = payload.is_a?(Hash) && payload.key?(:id) || (payload.is_a?(Hash) && payload.key?("id"))

        Thread.new do
          begin
            dispatch_post(body, is_request: is_request)
          rescue StandardError => e
            @last_error = e
            @on_message&.call({
              "id"    => payload[:id] || payload["id"],
              "error" => { "code" => -32000, "message" => "HTTP transport error: #{e.message}" }
            })
          end
        end
      end

      def on_message(&blk)
        @on_message = blk
      end

      def stderr_tail(bytes: 4096)
        @last_error ? "last error: #{@last_error.class}: #{@last_error.message}" : ""
      end

      private def dispatch_post(body, is_request:)
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = (@uri.scheme == "https")
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        req = Net::HTTP::Post.new(@uri.request_uri)
        req["Content-Type"] = "application/json"
        req["Accept"]       = "application/json, text/event-stream"
        req["MCP-Protocol-Version"] = Client::PROTOCOL_VERSION if defined?(Client::PROTOCOL_VERSION)
        @lock.synchronize { req["Mcp-Session-Id"] = @session_id if @session_id }
        @extra_headers.each { |k, v| req[k] = v }
        req.body = body

        http.request(req) do |res|
          if (sid = res["Mcp-Session-Id"])
            @lock.synchronize { @session_id = sid }
          end

          status = res.code.to_i
          if status == 202
            return
          end
          if status >= 400
            text = res.read_body.to_s
            raise TransportError, "HTTP #{status} from MCP server '#{@name}': #{text[0, 500]}"
          end

          ctype = (res["Content-Type"] || "").downcase
          if ctype.include?("text/event-stream")
            consume_sse(res)
          else
            text = res.read_body.to_s
            return if text.strip.empty?
            begin
              msg = JSON.parse(text)
            rescue JSON::ParserError => e
              raise TransportError, "invalid JSON from MCP server '#{@name}': #{e.message}"
            end
            deliver(msg)
          end
        end
      end

      private def consume_sse(res)
        buffer = String.new
        res.read_body do |chunk|
          buffer << chunk
          while (idx = buffer.index("\n\n"))
            event = buffer.slice!(0, idx + 2)
            data_lines = event.each_line.map(&:chomp).select { |l| l.start_with?("data:") }
            next if data_lines.empty?
            payload = data_lines.map { |l| l.sub(/\Adata:\s?/, "") }.join("\n")
            next if payload.empty?
            begin
              msg = JSON.parse(payload)
            rescue JSON::ParserError
              next
            end
            deliver(msg)
          end
        end
      end

      private def deliver(msg)
        if msg.is_a?(Array)
          msg.each { |m| @on_message&.call(m) }
        else
          @on_message&.call(msg)
        end
      end
    end
  end
end
