# frozen_string_literal: true

# asr_proxy.rb — WebSocket proxy for ASR (Automatic Speech Recognition)
#
# Relays browser WebSocket audio streams to upstream ASR providers
# (DashScope, iFlytek, etc.) and routes recognition results back.
#
# The proxy is transparent: it adds authentication headers to the
# upstream connection but does not parse or modify the data stream.
#
# Provider selection is read from the user's settings; the API key
# is never exposed to the frontend.

require "websocket"
require "socket"

module Clacky
  module AsrProxy
    DASHSCOPE_WS_URL = "wss://dashscope.aliyuncs.com/api-ws/v1/inference/".freeze

    # Handle an incoming ASR proxy WebSocket connection from the browser.
    #
    #   req - WEBrick::HTTPRequest (the upgrade request from the browser)
    #   settings - Hash with :asr_provider and :asr_api_key
    #
    # This hijacks the TCP socket, performs the WebSocket handshake,
    # connects to the upstream ASR provider, and relays data in both
    # directions until either side disconnects.
    def self.handle(req, settings)
      socket = req.instance_variable_get(:@socket)

      # ── 1. Complete WebSocket handshake with the browser ──────────────
      handshake = WebSocket::Handshake::Server.new
      handshake << build_handshake_request(req)
      unless handshake.finished? && handshake.valid?
        Clacky::Logger.warn("[AsrProxy] Browser handshake invalid")
        return
      end

      socket.write(handshake.to_s)
      version = handshake.version

      provider = settings[:asr_provider] || "dashscope"
      api_key  = settings[:asr_api_key]

      if api_key.nil? || api_key.empty?
        Clacky::Logger.warn("[AsrProxy] No API key configured for #{provider}")
        close_socket(socket)
        return
      end

      # ── 2. Connect to upstream ASR provider ───────────────────────────
      upstream_url  = upstream_url_for(provider)
      upstream_extra_headers = upstream_headers(provider, api_key)

      Clacky::Logger.info("[AsrProxy] Connecting upstream: #{provider} -> #{upstream_url}")

      uri = URI.parse(upstream_url)
      upstream_socket = open_upstream(uri, upstream_extra_headers)
      unless upstream_socket
        Clacky::Logger.error("[AsrProxy] Failed to connect to #{provider}")
        close_socket(socket)
        return
      end

      # ── 3. Bidirectional relay ────────────────────────────────────────
      relay(socket, upstream_socket, version)
    rescue => e
      Clacky::Logger.error("[AsrProxy] Error: #{e.class}: #{e.message}")
    ensure
      close_socket(socket)
    end

    # ── Private helpers ──────────────────────────────────────────────────

    def self.upstream_url_for(provider)
      case provider
      when "dashscope"
        DASHSCOPE_WS_URL
      when "iflytek"
        # Future: iFlytek real-time ASR WebSocket endpoint
        "wss://iat-api.xfyun.cn/v2/iat"
      else
        DASHSCOPE_WS_URL
      end
    end

    def self.upstream_headers(provider, api_key)
      case provider
      when "dashscope"
        { "Authorization" => "bearer #{api_key}",
          "X-DashScope-DataInspection" => "enable" }
      when "iflytek"
        { "X-Api-Key" => api_key }
      else
        { "Authorization" => "bearer #{api_key}" }
      end
    end

    def self.open_upstream(uri, extra_headers)
      tcp = TCPSocket.new(uri.host, uri.port || (uri.scheme == "wss" ? 443 : 80))

      if uri.scheme == "wss"
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        ctx.ca_file = OpenSSL::X509::DEFAULT_CERT_FILE
        tcp = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        tcp.hostname = uri.host
        tcp.connect
      end

      # Perform client WebSocket handshake
      hs = WebSocket::Handshake::Client.new(url: uri.to_s)
      extra_headers.each { |k, v| hs.headers[k] = v }
      tcp.write(hs.to_s)

      # Read server response
      response = +""
      loop do
        chunk = tcp.readpartial(4096) rescue nil
        break unless chunk
        response << chunk
        hs << chunk
        break if hs.finished?
      end

      unless hs.valid?
        Clacky::Logger.warn("[AsrProxy] Upstream handshake INVALID: #{hs.error}")
        Clacky::Logger.warn("[AsrProxy] Upstream response: #{response[0..500]}")
        tcp.close rescue nil
        return nil
      end

      tcp
    rescue => e
      Clacky::Logger.error("[AsrProxy] Upstream connection failed: #{e.message}")
      nil
    end

    # Bidirectional relay between browser and upstream.
    # Uses IO.select for non-blocking multiplexing.
    def self.relay(browser_socket, upstream, ws_version)
      incoming = WebSocket::Frame::Incoming::Server.new(version: ws_version)
      upstream_incoming = WebSocket::Frame::Incoming::Client.new(version: ws_version)
      upstream_buf = String.new("", encoding: "BINARY")
      out_client = WebSocket::Frame::Outgoing::Client
      out_server = WebSocket::Frame::Outgoing::Server

      loop do
        readable, _, _ = IO.select([browser_socket, upstream], nil, nil, 30)
        break unless readable

        # Browser → Upstream
        if readable.include?(browser_socket)
          begin
            chunk = browser_socket.read_nonblock(65536, exception: false)
            case chunk
            when :wait_readable
              # Will retry on next select
            when nil
              break # EOF
            else
              incoming << chunk
              while (frame = incoming.next)
                case frame.type
                when :text, :binary
                  begin
                    upstream.write(out_client.new(version: ws_version, data: frame.data, type: frame.type).to_s)
                  rescue => e
                    Clacky::Logger.warn("[AsrProxy] Relay browser→upstream write: #{e.class}: #{e.message}")
                    break
                  end
                when :ping
                  begin
                    browser_socket.write(out_server.new(version: ws_version, type: :pong, data: frame.data).to_s)
                  rescue => e
                    Clacky::Logger.warn("[AsrProxy] Relay browser pong write: #{e.class}: #{e.message}")
                    break
                  end
                when :close
                  begin
                    upstream.close
                  rescue => e
                    Clacky::Logger.warn("[AsrProxy] Relay close upstream on browser close: #{e.class}: #{e.message}")
                  end
                  break
                end
              end
            end
          rescue IOError, Errno::ECONNRESET, Errno::EPIPE => e
            Clacky::Logger.warn("[AsrProxy] Relay browser read error: #{e.class}: #{e.message}")
            break
          end
        end

        # Upstream → Browser
        if readable.include?(upstream)
          begin
            chunk = upstream.read_nonblock(65536, upstream_buf, exception: false)
            case chunk
            when :wait_readable
              # Will retry on next select
            when nil
              break # EOF
            else
              upstream_incoming << chunk.dup
              while (frame = upstream_incoming.next)
                case frame.type
                when :text, :binary
                  begin
                    browser_socket.write(out_server.new(version: ws_version, data: frame.data, type: frame.type).to_s)
                  rescue => e
                    Clacky::Logger.warn("[AsrProxy] Relay upstream→browser write: #{e.class}: #{e.message}")
                    break
                  end
                when :ping
                  begin
                    upstream.write(out_client.new(version: ws_version, data: frame.data, type: :pong).to_s)
                  rescue => e
                    Clacky::Logger.warn("[AsrProxy] Relay upstream pong write: #{e.class}: #{e.message}")
                  end
                when :pong
                  # Ignore pong from upstream
                when :close
                  begin
                    browser_socket.write(out_server.new(version: ws_version, type: :close, data: "").to_s)
                  rescue => e
                    Clacky::Logger.warn("[AsrProxy] Relay browser close write: #{e.class}: #{e.message}")
                  end
                  break
                end
              end
            end
          rescue IOError, Errno::ECONNRESET, Errno::EPIPE => e
            Clacky::Logger.warn("[AsrProxy] Relay upstream read error: #{e.class}: #{e.message}")
            break
          end
        end
      end
    rescue => e
      Clacky::Logger.error("[AsrProxy] Relay error: #{e.class}: #{e.message}")
    ensure
      close_socket(upstream)
    end

    def self.close_socket(socket)
      socket.close rescue nil
    end

    # Build a handshake request string from a WEBrick HTTPRequest for
    # the WebSocket::Handshake::Server parser.
    def self.build_handshake_request(req)
      lines = ["#{req.request_method} #{req.path} HTTP/1.1"]
      req.header.each do |k, vals|
        v = vals.is_a?(Array) ? vals.join(", ") : vals.to_s
        next if k == "content-length" || k == "content-type"
        lines << "#{k}: #{v}"
      end
      lines << ""
      lines << ""
      lines.join("\r\n")
    end
  end
end
