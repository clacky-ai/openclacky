# frozen_string_literal: true

require "websocket"
require "json"
require "uri"
require "openssl"
require "socket"

module Clacky
  module Channel
    module Adapters
      module Qq
        # WebSocket client for the QQ Official Bot gateway.
        #
        # Op codes (QQ, differs from Discord):
        #   0  Dispatch          1  Heartbeat         2  Identify
        #   6  Resume            7  Reconnect         9  Invalid Session
        #   10 Hello             11 Heartbeat ACK
        #
        # Docs: https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html
        class GatewayClient
          READ_TIMEOUT_S  = 90
          # Exponential backoff between connection attempts: BASE * 2**n seconds
          # (with +/-50% jitter), capped at MAX_BACKOFF. Reset once READY/RESUMED.
          BASE_BACKOFF_S  = 2
          MAX_BACKOFF_S   = 60

          # Close codes that forbid further connection.
          FATAL_CLOSE_CODES = [4010, 4011, 4012, 4013, 4014, 4914, 4915].freeze
          # Close codes after which Identify (not Resume) must be sent.
          NEEDS_IDENTIFY_CODES = [4006, 4007, 4008, 4009].freeze

          class AuthError < StandardError; end

          # @param url [String] wss gateway URL (from getGateway)
          # @param token [String] raw bot access_token (this class adds "QQBot ")
          # @param intents [Integer] subscribed intent bitmask
          # @param shard [Array<Integer>] [shard_id, total_shards]
          # @param token_provider [Proc, nil] optional callable returning a fresh
          #   access_token; called before each (re)connect so an expired token
          #   (QQ tokens live ~2h) never causes endless Authentication fail.
          def initialize(url:, token:, intents:, shard: [0, 1], token_provider: nil)
            @url            = url
            @token          = token
            @token_provider = token_provider
            @intents        = intents
            @shard          = shard
            @running        = false

            @on_event = nil

            @session_id         = nil
            @last_seq           = nil
            @heartbeat_interval = nil
            @heartbeat_acked    = true
            @heartbeat_thread   = nil

            @force_identify = false

            # Number of consecutive failed connection attempts (for backoff).
            @reconnect_attempts = 0

            @socket     = nil
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
                Clacky::Logger.error("[qq-gw] error: #{e.message}")
                break unless @running
              end
              # Both normal disconnects (return) and exceptions above fall through
              # to a single, backed-off retry so we never hammer the gateway.
              wait_with_backoff if @running
            end
          end

          def stop
            @running = false
            @heartbeat_thread&.kill
            send_raw_frame(:close, "") rescue nil
            @socket&.close rescue nil
          end

          private def connect_and_listen
            refresh_token!
            uri  = URI.parse(@url)
            port = uri.port || 443

            Clacky::Logger.info("[qq-gw] connecting to #{uri.host}:#{port} (resume=#{can_resume?})")

            tcp = TCPSocket.new(uri.host, port)
            ctx = OpenSSL::SSL::SSLContext.new
            ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
            ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
            ssl.hostname = uri.host
            ssl.sync_close = true
            ssl.connect

            handshake = WebSocket::Handshake::Client.new(url: @url)
            ssl.write(handshake.to_s)
            handshake << ssl.readpartial(4096) until handshake.finished?
            raise "Gateway WebSocket handshake failed" unless handshake.valid?

            @ws_version = handshake.version
            @socket     = ssl
            @ws_open    = true
            @incoming   = WebSocket::Frame::Incoming::Client.new(version: @ws_version)
            @heartbeat_acked = true

            loop do
              break unless @running

              ready = IO.select([ssl], nil, nil, READ_TIMEOUT_S)
              unless ready
                Clacky::Logger.warn("[qq-gw] read timeout, reconnecting")
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
          rescue IOError, Errno::ECONNRESET, Errno::EPIPE,
                 Errno::ETIMEDOUT, OpenSSL::SSL::SSLError => e
            Clacky::Logger.info("[qq-gw] connection lost (#{e.class}: #{e.message})")
          ensure
            @ws_open = false
            @socket  = nil
            @heartbeat_thread&.kill
            ssl&.close rescue nil
          end

          private def handle_payload(payload)
            op   = payload["op"]
            data = payload["d"]
            seq  = payload["s"]
            type = payload["t"]

            @last_seq = seq unless seq.nil?

            case op
            when 10 # Hello
              @heartbeat_interval = data["heartbeat_interval"]
              Clacky::Logger.info("[qq-gw] hello, heartbeat_interval=#{@heartbeat_interval}ms")
              start_heartbeat_thread
              if can_resume?
                send_resume
              else
                send_identify
              end
            when 0 # Dispatch
              handle_dispatch(type, data)
            when 1 # Server-requested heartbeat
              send_heartbeat
            when 7 # Reconnect
              Clacky::Logger.info("[qq-gw] server requested reconnect")
              @socket&.close rescue nil
            when 9 # Invalid session
              resumable = data == true
              Clacky::Logger.warn("[qq-gw] invalid session (resumable=#{resumable})")
              drop_session unless resumable
              # Close now; the outer loop applies exponential backoff uniformly.
              @socket&.close rescue nil
            when 11 # Heartbeat ACK
              @heartbeat_acked = true
            end
          end

          private def handle_dispatch(type, data)
            case type
            when "READY"
              @session_id = data["session_id"]
              @force_identify = false
              reset_backoff
              user = data["user"] || {}
              Clacky::Logger.info("[qq-gw] READY as #{user["username"]} (id=#{user["id"]}), session=#{@session_id}")
            when "RESUMED"
              reset_backoff
              Clacky::Logger.info("[qq-gw] RESUMED session=#{@session_id}")
            else
              # Message / interaction events — forward the full payload upstream.
              @on_event&.call(type: type, data: data)
            end
          rescue => e
            Clacky::Logger.error(
              "[qq-gw] dispatch handler error (#{type}): #{e.message}\n" \
              "#{e.backtrace.first(3).join("\n")}"
            )
          end

          private def handle_close_frame(data)
            code   = data.respond_to?(:code) ? data.code : nil
            reason = data.respond_to?(:data) ? data.data : data.to_s
            Clacky::Logger.warn("[qq-gw] close frame code=#{code} reason=#{reason}")

            if code && FATAL_CLOSE_CODES.include?(code)
              @running = false
              raise AuthError, "QQ rejected connection (code=#{code}): #{reason}"
            end

            return unless code && NEEDS_IDENTIFY_CODES.include?(code)

            drop_session
          end

          private def reset_backoff
            @reconnect_attempts = 0
          end

          private def wait_with_backoff
            delay = backoff_seconds
            Clacky::Logger.info("[qq-gw] reconnecting in #{delay.round(1)}s (attempt #{@reconnect_attempts})")
            Clacky::Shutdown.sleep(delay)
          end

          # BASE * 2**n capped at MAX, with +/-50% random jitter to avoid a
          # synchronized reconnect storm across many bots.
          private def backoff_seconds
            n = @reconnect_attempts
            @reconnect_attempts += 1
            base = [BASE_BACKOFF_S * (2**n), MAX_BACKOFF_S].min
            jitter = base * 0.5 * (2 * rand - 1)
            [[base + jitter, 0.5].max, MAX_BACKOFF_S].min
          end

          # Fetch a fresh access_token before (re)connecting. Only used when a
          # token_provider was supplied; failures are non-fatal so we still try
          # with the current token.
          private def refresh_token!
            return unless @token_provider

            @token = @token_provider.call.to_s
          rescue StandardError => e
            Clacky::Logger.warn("[qq-gw] token refresh failed: #{e.message}")
          end

          private def can_resume?
            !@force_identify && !@session_id.nil? && !@last_seq.nil?
          end

          private def drop_session
            @session_id     = nil
            @last_seq       = nil
            @force_identify = true
          end

          private def send_identify
            Clacky::Logger.info("[qq-gw] sending Identify (intents=#{@intents}, shard=#{@shard.inspect})")
            send_payload(
              op: 2,
              d: {
                token: "QQBot #{@token}",
                intents: @intents,
                shard: @shard,
                properties: { "$os" => RUBY_PLATFORM, "$browser" => "openclacky", "$device" => "openclacky" }
              }
            )
          end

          private def send_resume
            Clacky::Logger.info("[qq-gw] sending Resume (session=#{@session_id} seq=#{@last_seq})")
            send_payload(
              op: 6,
              d: { token: "QQBot #{@token}", session_id: @session_id, seq: @last_seq }
            )
          end

          private def send_heartbeat
            unless @heartbeat_acked
              Clacky::Logger.warn("[qq-gw] missed heartbeat ack, forcing reconnect")
              @socket&.close rescue nil
              return
            end
            @heartbeat_acked = false
            send_payload(op: 1, d: @last_seq)
          end

          private def start_heartbeat_thread
            @heartbeat_thread&.kill
            interval_s = @heartbeat_interval.to_f / 1000
            jitter     = rand
            @heartbeat_thread = Clacky::ThreadRegistry.spawn(name: "qq-gw-heartbeat") do
              Clacky::Shutdown.sleep(interval_s * jitter)
              loop do
                break unless @running && @ws_open

                Clacky::Shutdown.checkpoint!
                begin
                  send_heartbeat
                rescue => e
                  Clacky::Logger.warn("[qq-gw] heartbeat send failed: #{e.message}")
                  @socket&.close rescue nil
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
            return unless @socket && @ws_open

            outgoing = WebSocket::Frame::Outgoing::Client.new(
              version: @ws_version || 13,
              data: data,
              type: type
            )
            @socket.write(outgoing.to_s)
          end
        end
      end
    end
  end
end
