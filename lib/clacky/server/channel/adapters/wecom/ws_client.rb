# frozen_string_literal: true

require "websocket/driver"
require "json"
require "uri"
require "securerandom"

module Clacky
  module Channel
    module Adapters
      module Wecom
        # WebSocket client for WeCom (Enterprise WeChat) intelligent robot long connection.
        # Protocol: plain JSON frames over wss://openws.work.weixin.qq.com
        #
        # Frame format: { cmd, headers: { req_id }, body }
        # Commands:
        #   aibot_subscribe      - auth (client → server)
        #   ping                 - heartbeat (client → server)
        #   aibot_msg_callback   - inbound message (server → client)
        #   aibot_respond_msg    - send reply (client → server)
        class WSClient
          WS_URL = "wss://openws.work.weixin.qq.com"
          HEARTBEAT_INTERVAL = 30 # seconds
          RECONNECT_DELAY = 5     # seconds

          # Raised when WeCom rejects credentials — signals caller not to retry.
          class AuthError < StandardError; end

          def initialize(bot_id:, secret:, ws_url: WS_URL)
            @bot_id = bot_id
            @secret = secret
            @ws_url = ws_url
            @running = false
            @ws = nil
            @ping_thread = nil
            @mutex = Mutex.new
            @pending_acks = {}
          end

          def start(&on_message)
            @running = true
            @on_message = on_message

            while @running
              begin
                connect_and_listen
              rescue AuthError => e
                Clacky::Logger.error("[WecomWSClient] Authentication failed (not retrying): #{e.message}")
                @running = false
                raise
              rescue => e
                Clacky::Logger.error("[WecomWSClient] WebSocket error: #{e.message}")
                sleep RECONNECT_DELAY if @running
              end
            end
          end

          def stop
            @running = false
            @ping_thread&.kill
            @ws&.close
          end

          # Proactively send a text message
          # @param chatid [String] chat ID
          # @param content [String] text content
          def send_message(chatid, content)
            Clacky::Logger.info("[WecomWSClient] send_message chat=#{chatid} length=#{content.length}")
            send_frame_and_wait(
              cmd: "aibot_send_msg",
              req_id: generate_req_id("send"),
              body: {
                chatid: chatid,
                msgtype: "markdown",
                markdown: { content: content }
              }
            )
          end

          # Upload a local file as a temporary media asset and send it to a chat.
          # Uses the three-step chunked upload protocol:
          #   aibot_upload_media_init → aibot_upload_media_chunk × N → aibot_upload_media_finish
          # Then sends the resulting media_id via aibot_send_msg.
          #
          # @param chatid   [String] target chat ID
          # @param path     [String] absolute path to the local file
          # @param name     [String, nil] display filename (defaults to File.basename(path))
          # @param type     [String] media type — "file" or "image"
          def send_file(chatid, path, name: nil, type: nil)
            Clacky::Logger.info("[WecomWSClient] send_file chat=#{chatid} path=#{path}")
            raise ArgumentError, "File not found: #{path}" unless File.exist?(path)

            data      = File.binread(path)
            filename  = name || File.basename(path)
            media_type = type || detect_media_type(path)

            Clacky::Logger.info("[WecomWSClient] uploading #{filename} (#{data.bytesize} bytes, type=#{media_type})")
            media_id = upload_media(data, filename: filename, type: media_type)
            Clacky::Logger.info("[WecomWSClient] upload done media_id=#{media_id}")

            req_id = generate_req_id("send_file")
            send_frame_and_wait(
              cmd: "aibot_send_msg",
              req_id: req_id,
              body: {
                chatid: chatid,
                msgtype: media_type,
                media_type => { media_id: media_id }
              }
            )
            Clacky::Logger.info("[WecomWSClient] send_file frame sent chat=#{chatid} filename=#{filename}")
          rescue => e
            Clacky::Logger.error("[WecomWSClient] send_file failed (#{File.basename(path)}): #{e.message}")
            raise
          end

          private

          def connect_and_listen
            uri = URI.parse(@ws_url)
            port = uri.port || 443

            Clacky::Logger.info("[WecomWSClient] connecting to #{uri.host}:#{port}")

            require "openssl"
            tcp = TCPSocket.new(uri.host, port)
            ssl_context = OpenSSL::SSL::SSLContext.new
            ssl_context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
            ssl = OpenSSL::SSL::SSLSocket.new(tcp, ssl_context)
            ssl.sync_close = true
            ssl.connect

            wrapper = SocketWrapper.new(ssl, @ws_url)
            @ws = WebSocket::Driver.client(wrapper)

            @ws.on :open do
              Clacky::Logger.info("[WecomWSClient] connected, authenticating")
              authenticate
              start_ping_thread
            end

            @ws.on :message do |event|
              handle_message(event.data)
            end

            @ws.on :error do |event|
              Clacky::Logger.error("[WecomWSClient] WS error: #{event.message}")
            end

            @ws.on :close do
              Clacky::Logger.info("[WecomWSClient] connection closed")
            end

            @ws.start

            loop do
              break unless @running
              data = ssl.readpartial(4096)
              @ws.parse(data)
            end
          rescue EOFError, Errno::ECONNRESET
            Clacky::Logger.info("[WecomWSClient] connection lost, reconnecting...")
          ensure
            ssl&.close rescue nil
            @ping_thread&.kill
          end

          def authenticate
            Clacky::Logger.info("[WecomWSClient] sending auth (bot_id=#{@bot_id})")
            send_frame(
              cmd: "aibot_subscribe",
              req_id: generate_req_id("subscribe"),
              body: { bot_id: @bot_id, secret: @secret }
            )
          end

          def handle_message(data)
            frame = JSON.parse(data)
            cmd = frame["cmd"]
            body = frame["body"] || {}
            req_id = frame.dig("headers", "req_id") || ""

            # Dispatch ack to any waiting send_frame_and_wait caller
            if req_id && !req_id.empty?
              queue = @mutex.synchronize { @pending_acks&.[](req_id) }
              if queue
                queue.push(frame)
                return
              end
            end

            case cmd
            when "aibot_msg_callback"
              Clacky::Logger.info("[WecomWSClient] inbound message req_id=#{req_id}")
              cb_body = body.merge("_req_id" => req_id)
              Thread.new { @on_message&.call(cb_body) }
            when "aibot_event_callback"
              Clacky::Logger.info("[WecomWSClient] event_callback (ignored)")
            when nil
              errcode = frame["errcode"] || body["errcode"]
              if errcode && errcode != 0
                Clacky::Logger.error("[WecomWSClient] error response: #{frame.inspect}")
                if req_id.start_with?("subscribe_")
                  errmsg = frame["errmsg"] || body["errmsg"] || "unknown error"
                  @running = false
                  raise AuthError, "WeCom authentication failed (errcode=#{errcode}): #{errmsg}"
                end
              else
                if req_id.start_with?("ping_")
                  Clacky::Logger.debug("[WecomWSClient] ack/heartbeat req_id=#{req_id}")
                else
                  Clacky::Logger.info("[WecomWSClient] ack/heartbeat req_id=#{req_id}")
                end
              end
            else
              Clacky::Logger.info("[WecomWSClient] unknown cmd=#{cmd}")
            end
          rescue JSON::ParserError => e
            Clacky::Logger.error("[WecomWSClient] failed to parse message: #{e.message}")
          end

          def send_frame(cmd:, req_id:, body: nil)
            frame = { cmd: cmd, headers: { req_id: req_id } }
            frame[:body] = body if body
            if cmd == "ping"
              Clacky::Logger.debug("[WecomWSClient] >> cmd=#{cmd} req_id=#{req_id}")
            else
              Clacky::Logger.info("[WecomWSClient] >> cmd=#{cmd} req_id=#{req_id}")
            end
            @ws.text(JSON.generate(frame))
          rescue => e
            Clacky::Logger.error("[WecomWSClient] failed to send frame cmd=#{cmd}: #{e.message}")
          end

          def start_ping_thread
            @ping_thread&.kill
            @ping_thread = Thread.new do
              loop do
                sleep HEARTBEAT_INTERVAL
                break unless @running
                send_frame(cmd: "ping", req_id: generate_req_id("ping"))
              end
            end
          end

          def generate_req_id(prefix)
            "#{prefix}_#{SecureRandom.hex(8)}"
          end

          CHUNK_SIZE = 512 * 1024  # 512 KB per chunk (before Base64)
          MAX_CHUNKS = 100

          # Three-step chunked media upload over WebSocket.
          # Returns media_id on success.
          def upload_media(data, filename:, type: "file")
            require "base64"
            require "digest"

            total_size   = data.bytesize
            total_chunks = (total_size.to_f / CHUNK_SIZE).ceil
            total_chunks = 1 if total_chunks == 0
            raise ArgumentError, "File too large: #{total_chunks} chunks (max #{MAX_CHUNKS})" if total_chunks > MAX_CHUNKS

            md5 = Digest::MD5.hexdigest(data)

            Clacky::Logger.info("[WecomWSClient] upload_media_init filename=#{filename} size=#{total_size} chunks=#{total_chunks} md5=#{md5}")

            # Step 1: init
            init_req_id = generate_req_id("upload_init")
            init_result = send_frame_and_wait(
              cmd: "aibot_upload_media_init",
              req_id: init_req_id,
              body: { type: type, filename: filename, total_size: total_size, total_chunks: total_chunks, md5: md5 }
            )
            upload_id = init_result.dig("body", "upload_id")
            raise "upload_media init failed: #{init_result.inspect}" unless upload_id
            Clacky::Logger.info("[WecomWSClient] upload_id=#{upload_id}")

            # Step 2: chunks
            total_chunks.times do |i|
              chunk_start = i * CHUNK_SIZE
              chunk       = data[chunk_start, CHUNK_SIZE]
              b64         = Base64.strict_encode64(chunk)

              Clacky::Logger.info("[WecomWSClient] uploading chunk #{i + 1}/#{total_chunks}")
              chunk_req_id = generate_req_id("upload_chunk")
              send_frame_and_wait(
                cmd: "aibot_upload_media_chunk",
                req_id: chunk_req_id,
                body: { upload_id: upload_id, chunk_index: i, base64_data: b64 }
              )
            end

            # Step 3: finish
            Clacky::Logger.info("[WecomWSClient] upload_media_finish upload_id=#{upload_id}")
            finish_req_id = generate_req_id("upload_finish")
            finish_result = send_frame_and_wait(
              cmd: "aibot_upload_media_finish",
              req_id: finish_req_id,
              body: { upload_id: upload_id }
            )
            media_id = finish_result.dig("body", "media_id")
            raise "upload_media finish failed: #{finish_result.inspect}" unless media_id

            media_id
          end

          # Send a frame and block until an ack frame with the same req_id arrives.
          # Timeout after 30s. Returns the ack frame hash.
          def send_frame_and_wait(cmd:, req_id:, body: nil)
            queue = Queue.new

            @mutex.synchronize do
              @pending_acks ||= {}
              @pending_acks[req_id] = queue
            end

            send_frame(cmd: cmd, req_id: req_id, body: body)

            result = queue.pop(timeout: 30)
            raise "Timeout waiting for ack (req_id=#{req_id}, cmd=#{cmd})" if result.nil?

            errcode = result["errcode"] || result.dig("body", "errcode")
            if errcode && errcode != 0
              errmsg = result["errmsg"] || result.dig("body", "errmsg") || "unknown"
              raise "WeCom API error #{errcode}: #{errmsg} (cmd=#{cmd})"
            end

            result
          ensure
            @mutex.synchronize { @pending_acks&.delete(req_id) }
          end

          # Detect media type from file extension
          def detect_media_type(path)
            case File.extname(path).downcase
            when ".jpg", ".jpeg", ".png", ".gif", ".webp" then "image"
            when ".mp4", ".avi", ".mov", ".mkv"           then "video"
            when ".mp3", ".wav", ".amr", ".m4a"           then "voice"
            else "file"
            end
          end

          # Wraps a raw socket for websocket-driver client mode.
          class SocketWrapper
            attr_reader :url

            def initialize(socket, url)
              @socket = socket
              @url = url
            end

            def write(data)
              @socket.write(data)
            end
          end
        end
      end
    end
  end
end
