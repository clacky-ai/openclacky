# frozen_string_literal: true

require "websocket"
require "json"
require "uri"
require "openssl"
require "socket"

module Clacky
  module Channel
    module Adapters
      module Discord
        # WebSocket client for the Discord Gateway (v10, JSON, no compression).
        # Implements identify, heartbeat, resume, and intent-aware error handling.
        class GatewayClient
          GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json"

          # GUILDS | GUILD_MESSAGES | GUILD_MESSAGE_REACTIONS | DIRECT_MESSAGES | MESSAGE_CONTENT
          INTENTS = (1 << 0) | (1 << 9) | (1 << 10) | (1 << 12) | (1 << 15)

          FATAL_CLOSE_CODES = [4004, 4010, 4011, 4012, 4013, 4014].freeze
          RECONNECT_DELAY = 5
          READ_TIMEOUT_S  = 90

          class AuthError < StandardError; end

          def initialize(bot_token:)
            @bot_token = bot_token
            @running   = false
            @on_event  = nil

            @session_id          = nil
            @resume_gateway_url  = nil
            @last_seq            = nil
            @heartbeat_interval  = nil
            @heartbeat_acked     = true
            @heartbeat_thread    = nil

            @ws_socket  = nil
            @ws_open    = false
            @ws_version = nil
            @incoming   = nil
          end

          def start(&on_event)
            @running  = true
            @on_event = on_event

            while @running
              begin
                connect_and_listen
              rescue AuthError
                @running = false
                raise
              rescue => e
                Clacky::Logger.error("[DiscordGW] error: #{e.message}")
                break unless @running
                Clacky::Shutdown.sleep(RECONNECT_DELAY)
              end
            end
          end

          def stop
            @running = false
            @heartbeat_thread&.kill
            send_raw_frame(:close, "") rescue nil
            @ws_socket&.close rescue nil
          end

          private def connect_and_listen
            ssl = nil
            url = @resume_gateway_url ? "#{@resume_gateway_url}/?v=10&encoding=json" : GATEWAY_URL
            uri = URI.parse(url)
            port = uri.port || 443

            Clacky::Logger.info("[DiscordGW] connecting to #{uri.host}:#{port} (resume=#{!@session_id.nil?})")

            tcp = TCPSocket.new(uri.host, port)
            ctx = OpenSSL::SSL::SSLContext.new
            ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
            ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
            ssl.hostname = uri.host
            ssl.sync_close = true
            ssl.connect

            handshake = WebSocket::Handshake::Client.new(url: url)
            ssl.write(handshake.to_s)
            handshake << ssl.readpartial(4096) until handshake.finished?
            raise "Gateway WebSocket handshake failed" unless handshake.valid?

            @ws_version = handshake.version
            @ws_socket  = ssl
            @ws_open    = true
            @incoming   = WebSocket::Frame::Incoming::Client.new(version: @ws_version)
            @heartbeat_acked = true

            loop do
              break unless @running
              ready = IO.select([ssl], nil, nil, READ_TIMEOUT_S)
              unless ready
                Clacky::Logger.warn("[DiscordGW] read timeout, reconnecting")
                return
              end

              data = ssl.read_nonblock(4096)
              @incoming << data
              while (frame = @incoming.next)
                case frame.type
                when :text
                  handle_payload(JSON.parse(frame.data))
                when :ping
                  send_raw_frame(:pong, frame.data)
                when :close
                  handle_close_frame(frame.data)
                  return
                end
              end
            end
          rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE,
                 Errno::ETIMEDOUT, OpenSSL::SSL::SSLError => e
            Clacky::Logger.info("[DiscordGW] connection lost (#{e.class}: #{e.message})")
          ensure
            @ws_open = false
            @ws_socket = nil
            @heartbeat_thread&.kill
            ssl&.close rescue nil
          end

          private def handle_payload(payload)
            op   = payload["op"]
            data = payload["d"]
            seq  = payload["s"]
            type = payload["t"]

            @last_seq = seq if seq

            case op
            when 10
              @heartbeat_interval = data["heartbeat_interval"]
              Clacky::Logger.info("[DiscordGW] hello, heartbeat_interval=#{@heartbeat_interval}ms")
              start_heartbeat_thread
              if @session_id && @resume_gateway_url
                send_resume
              else
                send_identify
              end
            when 0
              handle_dispatch(type, data)
            when 1
              send_heartbeat
            when 7
              Clacky::Logger.info("[DiscordGW] server requested reconnect")
              @ws_socket&.close rescue nil
            when 9
              resumable = data == true
              Clacky::Logger.warn("[DiscordGW] invalid session (resumable=#{resumable})")
              unless resumable
                @session_id = nil
                @resume_gateway_url = nil
                @last_seq = nil
              end
              Clacky::Shutdown.sleep(rand(1..5))
              @ws_socket&.close rescue nil
            when 11
              @heartbeat_acked = true
            end
          end

          private def handle_dispatch(type, data)
            case type
            when "READY"
              @session_id         = data["session_id"]
              @resume_gateway_url = data["resume_gateway_url"]
              user = data["user"] || {}
              Clacky::Logger.info("[DiscordGW] READY as #{user["username"]} (id=#{user["id"]}), session=#{@session_id}")
            when "RESUMED"
              Clacky::Logger.info("[DiscordGW] RESUMED session=#{@session_id}")
            when "MESSAGE_CREATE"
              @on_event&.call(type: :message, data: data)
            end
          rescue => e
            Clacky::Logger.error("[DiscordGW] dispatch handler error (#{type}): #{e.message}\n#{e.backtrace.first(3).join("\n")}")
          end

          private def handle_close_frame(data)
            code   = data.respond_to?(:code) ? data.code : nil
            reason = data.respond_to?(:data) ? data.data : data.to_s
            Clacky::Logger.warn("[DiscordGW] close frame code=#{code} reason=#{reason}")
            if code && FATAL_CLOSE_CODES.include?(code)
              @running = false
              raise AuthError, "Discord rejected connection (code=#{code}): #{reason}"
            end
          end

          private def send_identify
            Clacky::Logger.info("[DiscordGW] sending Identify (intents=#{INTENTS})")
            client_id = self.class.client_identifier
            send_payload(
              op: 2,
              d: {
                token: @bot_token,
                intents: INTENTS,
                properties: {
                  os:      RUBY_PLATFORM,
                  browser: client_id,
                  device:  client_id
                }
              }
            )
          end

          def self.client_identifier
            name = Clacky::BrandConfig.load.product_name
            name = "OpenClacky" if name.nil? || name.strip.empty?
            "#{name.strip}/#{Clacky::VERSION}"
          end

          private def send_resume
            Clacky::Logger.info("[DiscordGW] sending Resume (session=#{@session_id} seq=#{@last_seq})")
            send_payload(
              op: 6,
              d: { token: @bot_token, session_id: @session_id, seq: @last_seq }
            )
          end

          private def send_heartbeat
            unless @heartbeat_acked
              Clacky::Logger.warn("[DiscordGW] missed heartbeat ack, forcing reconnect")
              @ws_socket&.close rescue nil
              return
            end
            @heartbeat_acked = false
            send_payload(op: 1, d: @last_seq)
          end

          private def start_heartbeat_thread
            @heartbeat_thread&.kill
            interval_s = @heartbeat_interval.to_f / 1000.0
            jitter     = rand
            @heartbeat_thread = Clacky::ThreadRegistry.spawn(name: "discord-gw-heartbeat") do
              Clacky::Shutdown.sleep(interval_s * jitter)
              loop do
                break unless @running && @ws_open
                Clacky::Shutdown.checkpoint!
                begin
                  send_heartbeat
                rescue => e
                  Clacky::Logger.warn("[DiscordGW] heartbeat send failed: #{e.message}")
                  @ws_socket&.close rescue nil
                  break
                end
                Clacky::Shutdown.sleep(interval_s)
              end
            end
          end

          private def send_payload(payload)
            send_raw_frame(:text, JSON.generate(payload))
          end

          private def send_raw_frame(type, data)
            return unless @ws_socket && @ws_open
            outgoing = WebSocket::Frame::Outgoing::Client.new(
              version: @ws_version || 13,
              data:    data,
              type:    type
            )
            @ws_socket.write(outgoing.to_s)
          end
        end
      end
    end
  end
end
