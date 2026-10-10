# frozen_string_literal: true

require "json"
require "time"
require "digest"
require "uri"
require "net/http"
require_relative "../../adapters/base"
require_relative "api_client"
require_relative "gateway_client"

module Clacky
  module Channel
    module Adapters
      # QQ Official Bot (QQ 开放平台) channel adapter.
      module Qq
        # Adapter for the QQ Official Bot API (QQ 开放平台).
        #
        # Supported scopes:
        #   c2c    单聊   event C2C_MESSAGE_CREATE      (inbound + outbound)
        #   group  群 @   event GROUP_AT_MESSAGE_CREATE (inbound + outbound)
        #
        # Guild messages (AT_MESSAGE_CREATE) are received and parsed when guild
        # intents are configured explicitly, but outbound guild replies are not
        # implemented; send_text/send_file log a warning and return no message id.
        #
        # Outbound for group / c2c uses the v2 messages endpoints. A chat_id
        # encodes the scope so send_text knows which endpoint to call:
        #   "group:<group_openid>"
        #   "c2c:<user_openid>"
        #
        # Config (channels.yml `qq` section):
        #   app_id        String  required
        #   app_secret    String  required
        #   base_url      String  optional (default https://api.sgroup.qq.com)
        #   intents       Integer optional (default C2C + group @, bit 25)
        #   sandbox       Boolean optional (use sandbox base url)
        #   allowed_users Array   optional whitelist of openid
        class Adapter < Base
          # QQ currently places both C2C_MESSAGE_CREATE and
          # GROUP_AT_MESSAGE_CREATE under intent bit 25 (GROUP_AND_C2C_EVENT).
          INTENT_C2C_GROUP = 1 << 25

          # Guild-side intent for users who opt into guild inbound via `intents`.
          INTENT_PUBLIC_GUILD_MSG = 1 << 30

          # Default to C2C + group @ only. QQ rejects a single gateway connection
          # that combines bit 25 (C2C/group) with guild-side intents such as
          # PUBLIC_GUILD_MESSAGES (1<<30) or GUILDS (1<<0) with an "invalid
          # session" (op 9). Guild/channel mode still works but must be requested
          # explicitly via the `intents` config using guild intents only.
          DEFAULT_INTENTS = INTENT_C2C_GROUP

          SANDBOX_BASE_URL = "https://sandbox.api.sgroup.qq.com"

          # QQ group/c2c text payloads cap around 5000 chars; leave a margin.
          MAX_MESSAGE_CHARS = 4000

          # Bounded cache size for inbound msg_id dedupe.
          SEEN_ID_LIMIT = 500

          # Caps for downloading inbound attachments.
          MAX_IMAGE_DOWNLOAD_BYTES = 10 * 1024 * 1024 # 10 MB
          MAX_MEDIA_DOWNLOAD_BYTES = 32 * 1024 * 1024 # 32 MB

          def self.platform_id
            :qq
          end

          def self.env_keys
            %w[QQ_APP_ID QQ_APP_SECRET QQ_BASE_URL QQ_ALLOWED_USERS]
          end

          def self.platform_config(data)
            intents = data["intents"] || data["INTENTS"]
            cfg = {
              app_id: data["QQ_APP_ID"] || data["app_id"],
              app_secret: data["QQ_APP_SECRET"] || data["app_secret"],
              base_url: data["QQ_BASE_URL"] || data["base_url"],
              sandbox: data.key?("sandbox") ? data["sandbox"] : data["SANDBOX"],
              intents: intents.nil? ? DEFAULT_INTENTS : intents.to_i,
              allowed_users: parse_list(data["allowed_users"] || data["QQ_ALLOWED_USERS"])
            }
            cfg[:base_url] = SANDBOX_BASE_URL if cfg[:base_url].nil? && truthy?(cfg[:sandbox])
            cfg.compact
          end

          def self.set_env_data(data, config)
            data["QQ_APP_ID"] = config[:app_id]
            data["QQ_APP_SECRET"] = config[:app_secret]
            data["QQ_BASE_URL"] = config[:base_url] if config[:base_url]
            data["QQ_ALLOWED_USERS"] = Array(config[:allowed_users]).join(",")
          end

          # Test connectivity with provided credentials (does not persist).
          # Fetching an access token succeeds only when app_id/app_secret are valid.
          # @param fields [Hash] symbol-keyed credential fields
          # @return [Hash] { ok: Boolean, message: String }
          def self.test_connection(fields)
            app_id = fields[:app_id].to_s.strip
            app_secret = fields[:app_secret].to_s.strip

            return { ok: false, error: "app_id is required" } if app_id.empty?
            return { ok: false, error: "app_secret is required" } if app_secret.empty?

            api = ApiClient.new(app_id: app_id, app_secret: app_secret, base_url: fields[:base_url])
            token = api.access_token
            if token && !token.empty?
              { ok: true, message: "Connected — access token obtained" }
            else
              { ok: false, error: "Empty token returned — check app_id and app_secret" }
            end
          rescue => e
            { ok: false, error: e.message }
          end

          def self.parse_list(value)
            return [] if value.nil?

            arr = value.is_a?(Array) ? value : value.to_s.split(",")
            arr.map(&:to_s).map(&:strip).reject(&:empty?)
          end

          def self.truthy?(value)
            value == true || value.to_s.casecmp?("true") || value.to_s == "1"
          end

          def initialize(config)
            @config        = config
            @app_id        = config[:app_id].to_s
            @app_secret    = config[:app_secret].to_s
            @intents       = config[:intents].to_i
            @intents       = DEFAULT_INTENTS if @intents.zero?
            @allowed_users = Array(config[:allowed_users]).map(&:to_s)

            @api = ApiClient.new(
              app_id: @app_id,
              app_secret: @app_secret,
              base_url: config[:base_url]
            )

            @running      = false
            @on_message   = nil
            @gateway      = nil
            @msg_seq      = 0
            @last_msg_ids = {}
            @id_mutex     = Mutex.new

            # QQ may redeliver the same msg_id more than once; dedupe so the agent
            # does not react to a single message multiple times.
            @seen_ids   = {}
            @seen_mutex = Mutex.new
          end

          # Start listening for messages via WebSocket.
          # @yield [event] Yields standardized inbound messages
          # @return [void]
          def start(&on_message)
            @running    = true
            @on_message = on_message

            info = @api.connection_info
            Clacky::Logger.info("[qq] gateway=#{info[:url]} intents=#{@intents}")

            @gateway = GatewayClient.new(
              url: info[:url],
              token: info[:token],
              intents: @intents,
              token_provider: -> { @api.access_token }
            )

            @gateway.start do |event|
              process_event(event[:type], event[:data])
            rescue => e
              Clacky::Logger.warn("[qq] process_event error: #{e.message}")
              Clacky::Logger.warn(e.backtrace.first(3).join("\n"))
            end
          rescue ApiClient::ApiError
            Clacky::Logger.error("[qq] startup failed: #{$!.message}")
            raise
          end

          # Stop the adapter.
          # @return [void]
          def stop
            @running = false
            @gateway&.stop
          end

          # Send a text message.
          # @param chat_id [String] scope-encoded chat id ("group:<openid>" / "c2c:<openid>")
          # @param text [String] Message text
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] Result with :message_id
          def send_text(chat_id, text, reply_to: nil)
            scope, openid = parse_chat_id(chat_id)
            return { message_id: nil } unless openid

            unless %w[group c2c].include?(scope)
              Clacky::Logger.warn(
                "[qq] outbound messages are only supported for c2c/group chats, " \
                "got scope=#{scope}; guild (AT_MESSAGE_CREATE) replies are not implemented"
              )
              return { message_id: nil }
            end

            chunks = split_message(text.to_s)
            return { message_id: nil } if chunks.empty?

            last_id = nil
            chunks.each do |chunk|
              body = { content: chunk, msg_type: 0, msg_seq: next_seq }
              body[:msg_id] = reply_to.to_s if reply_to && !reply_to.to_s.empty?

              resp =
                case scope
                when "group" then @api.send_group_message(openid, body)
                when "c2c"   then @api.send_c2c_message(openid, body)
                end
              last_id = resp["id"] || resp["message_id"]
            end
            { message_id: last_id }
          rescue => e
            Clacky::Logger.error("[qq] send_text failed: #{e.message}")
            { message_id: nil }
          end

          # Send a local file (image / video / voice / generic document) via the
          # QQ rich-media pipeline: upload_prepare → PUT parts → part_finish →
          # /files (merge) → messages with msg_type 7.
          # @param chat_id [String] scope-encoded chat id
          # @param file_path [String] path on the local machine
          # @param name [String, nil] display filename (QQ derives the name from the path)
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] Result with :message_id
          def send_file(chat_id, file_path, name: nil, reply_to: nil)
            scope, openid = parse_chat_id(chat_id)
            return { message_id: nil } unless openid

            unless %w[group c2c].include?(scope)
              Clacky::Logger.warn(
                "[qq] outbound files are only supported for c2c/group chats, " \
                "got scope=#{scope}; guild replies are not implemented"
              )
              return { message_id: nil }
            end

            path = file_path.to_s
            raise Errno::ENOENT, path unless File.file?(path)

            file_type = classify_file(path)
            file_info = upload_local(scope, openid, path, file_type)
            send_media(scope, openid, file_info, reply_to: reply_to || last_msg_id_for(chat_id))
          rescue => e
            Clacky::Logger.error("[qq] send_file failed: #{e.message}")
            Clacky::Logger.error(e.backtrace.first(3).join("\n"))
            { message_id: nil }
          end

          # @return [Boolean]
          def supports_files?
            true
          end

          # @return [Boolean]
          def supports_message_updates?
            false
          end

          # Validate configuration.
          # @param config [Hash] Configuration to validate
          # @return [Array<String>] Error messages
          def validate_config(config)
            errors = []
            errors << "app_id is required" if config[:app_id].to_s.strip.empty?
            errors << "app_secret is required" if config[:app_secret].to_s.strip.empty?
            errors
          end

          # Dispatch an inbound gateway event.
          # @param type [String] QQ event name (e.g. "C2C_MESSAGE_CREATE")
          # @param data [Hash, nil] event payload
          # @return [void]
          def process_event(type, data)
            return unless data.is_a?(Hash)

            case type
            when "C2C_MESSAGE_CREATE"
              author = data["author"] || {}
              user_openid = author["user_openid"] || data["user_openid"]
              emit(data, scope: "c2c", chat_openid: user_openid, user_openid: user_openid, chat_type: :direct)
            when "GROUP_AT_MESSAGE_CREATE", "GROUP_MESSAGE_CREATE"
              author = data["author"] || {}
              member_openid = author["member_openid"] || author["id"] || data["member_openid"]
              emit(data, scope: "group", chat_openid: data["group_openid"], user_openid: member_openid,
                         chat_type: :group)
            when "AT_MESSAGE_CREATE"
              author = data["author"] || {}
              emit(data, scope: "guild", chat_openid: data["channel_id"], user_openid: author["id"],
                         chat_type: :group)
            end
          end

          # Cache the most recent inbound msg_id for a chat so an outbound file
          # message can reference it as a passive reply.
          def remember_msg_id(chat_id, message_id)
            @id_mutex.synchronize { @last_msg_ids[chat_id.to_s] = message_id.to_s }
          end

          def last_msg_id_for(chat_id)
            @id_mutex.synchronize { @last_msg_ids[chat_id.to_s] }
          end

          # Runs the chunked upload flow and returns the merged file_info string.
          private def upload_local(scope, openid, path, file_type)
            bytes = File.binread(path)
            name  = File.basename(path)

            prepare_body = {
              file_type: file_type,
              file_size: bytes.bytesize.to_s,
              file_name: name,
              md5: Digest::MD5.hexdigest(bytes),
              sha1: Digest::SHA1.hexdigest(bytes),
              md5_10m: Digest::MD5.hexdigest(bytes[0, 10_002_432] || +"")
            }
            prep = api_call(scope, :upload_prepare, openid, prepare_body)

            upload_id  = prep["upload_id"]
            block_size = prep["block_size"].to_i
            block_size = 5 * 1024 * 1024 if block_size <= 0
            parts      = Array(prep["parts"])
            offset     = 0

            # QQ's part index is 1-based even though the docs say 0-based, so
            # iterate in returned order with a running offset instead of using
            # index * block_size to slice bytes.
            parts.each do |part|
              index     = part["index"].to_i
              size      = part["block_size"].to_i
              size      = block_size if size <= 0
              chunk     = bytes.byteslice(offset, size) || +""
              presigned = part["presigned_url"]

              @api.put_raw(presigned, chunk)

              finish_body = {
                upload_id: upload_id,
                part_index: index,
                block_size: size.to_s,
                md5: Digest::MD5.hexdigest(chunk)
              }
              api_call(scope, :upload_part_finish, openid, finish_body)
              offset += size
            end

            merge_body = {
              file_type: file_type,
              srv_send_msg: false,
              file_name: name,
              upload_id: upload_id
            }
            merged = api_call(scope, :create_file, openid, merge_body)
            merged["file_info"].to_s
          end

          # Pushes a rich-media message (msg_type=7) referencing file_info.
          private def send_media(scope, openid, file_info, reply_to: nil)
            body = {
              msg_type: 7,
              media: { file_info: file_info },
              msg_seq: next_seq
            }
            body[:msg_id] = reply_to.to_s if reply_to && !reply_to.to_s.empty?

            resp =
              case scope
              when "group" then @api.send_group_message(openid, body)
              when "c2c"   then @api.send_c2c_message(openid, body)
              end
            { message_id: resp["id"] || resp["message_id"] }
          rescue => e
            Clacky::Logger.error("[qq] send_media failed: #{e.message}")
            { message_id: nil }
          end

          private def api_call(scope, step, openid, body)
            case [scope, step]
            when ["c2c", :upload_prepare]       then @api.upload_c2c_prepare(openid, body)
            when ["c2c", :upload_part_finish]   then @api.upload_c2c_part_finish(openid, body)
            when ["c2c", :create_file]          then @api.create_c2c_file(openid, body)
            when ["group", :upload_prepare]     then @api.upload_group_prepare(openid, body)
            when ["group", :upload_part_finish] then @api.upload_group_part_finish(openid, body)
            when ["group", :create_file]        then @api.create_group_file(openid, body)
            end
          end

          # QQ file_type: 1 image, 2 video, 3 voice(silk), 4 generic file.
          private def classify_file(path)
            ext = File.extname(path).to_s.downcase.delete(".")
            return 1 if %w[png jpg jpeg gif webp bmp].include?(ext)
            return 2 if %w[mp4 mov avi mkv].include?(ext)
            return 3 if %w[silk mp3 wav amr].include?(ext)

            4
          end

          private def emit(data, scope:, chat_openid:, user_openid:, chat_type:)
            chat_id = "#{scope}:#{chat_openid}"
            msg_id  = data["id"].to_s

            if @allowed_users.any? && !@allowed_users.include?(user_openid.to_s)
              Clacky::Logger.debug("[qq] ignoring message from #{user_openid} (not in allowed_users)")
              return
            end

            # QQ can push the same msg_id more than once; skip duplicates BEFORE
            # downloading attachments (up to 32 MB each).
            if duplicate?(msg_id)
              Clacky::Logger.debug("[qq] duplicate msg_id ignored: #{msg_id}")
              return
            end

            files = collect_files(data)
            text  = data["content"].to_s.strip

            # Voice messages expose a server-side ASR hint; surface it so the agent
            # can understand spoken input even without decoding SILK.
            asr = extract_asr(data)
            text = asr if text.empty? && !asr.empty?

            # Nothing textual and no usable attachment -> ignore (e.g. unsupported
            # rich media). Log at debug so it is traceable instead of vanishing.
            if text.empty? && files.empty?
              Clacky::Logger.debug(
                "[qq] empty message ignored scope=#{scope} " \
                "type=#{data["message_type"]} id=#{data["id"]}"
              )
              return
            end

            remember_msg_id(chat_id, msg_id)

            event = {
              type: :message,
              platform: :qq,
              chat_id: chat_id,
              user_id: user_openid.to_s,
              text: text,
              files: files,
              message_id: msg_id,
              timestamp: parse_time(data["timestamp"]),
              chat_type: chat_type,
              raw: data
            }

            Clacky::Logger.info("[qq] msg #{scope} from #{user_openid}: #{text.slice(0, 80)}")
            @on_message&.call(event)
          end

          # Returns true when this message id has already been handled. Keeps a
          # bounded insertion-ordered cache so the map cannot grow without limit.
          private def duplicate?(msg_id)
            return false if msg_id.nil? || msg_id.empty?

            @seen_mutex.synchronize do
              if @seen_ids.key?(msg_id)
                true
              else
                @seen_ids[msg_id] = true
                @seen_ids.shift while @seen_ids.size > SEEN_ID_LIMIT
                false
              end
            end
          end

          # Gather every usable attachment. Top-level attachments cover normal
          # messages; quoted/forwarded content (message_type=103) nests
          # attachments under msg_elements[], so walk those as well.
          private def collect_files(data)
            candidates = Array(data["attachments"]).dup
            Array(data["msg_elements"]).each do |el|
              candidates.concat(Array(el["attachments"])) if el.is_a?(Hash)
            end
            candidates.each_with_object([]) do |att, out|
              f = attachment_to_file(att)
              out << f if f
            end
          end

          # Map one MessageAttachment onto the event's file hash. The agent never
          # fetches remote URLs itself, so every attachment is downloaded to disk
          # here and exposed with a local :path.
          private def attachment_to_file(att)
            return nil unless att.is_a?(Hash)

            ctype    = att["content_type"].to_s
            filename = att["filename"]
            url      = att["url"].to_s
            kind     = classify_attachment(ctype)

            case kind
            when :image
              return nil if url.empty?

              body = download_attachment(url, limit: MAX_IMAGE_DOWNLOAD_BYTES) or return nil
              saved = Clacky::Utils::FileProcessor.save(body: body, filename: filename || "image.jpg")
              { type: :image, name: saved[:name], path: saved[:path], url: url,
                mime_type: normalized_image_mime(ctype), size: body.bytesize }
            when :video
              return nil if url.empty?

              body = download_attachment(url, limit: MAX_MEDIA_DOWNLOAD_BYTES) or return nil
              saved = Clacky::Utils::FileProcessor.save(body: body, filename: filename || "video.mp4")
              { type: :video, name: saved[:name], path: saved[:path], url: url,
                mime_type: "video/mp4", size: body.bytesize }
            when :voice
              # Prefer the transcoded WAV (plain PCM) over the raw SILK stream.
              wav = att["voice_wav_url"].to_s
              src = wav.empty? ? url : wav
              return nil if src.empty?

              body = download_attachment(src, limit: MAX_MEDIA_DOWNLOAD_BYTES) or return nil
              saved = Clacky::Utils::FileProcessor.save(body: body, filename: filename || "voice.wav")
              { type: :audio, name: saved[:name], path: saved[:path], url: src,
                mime_type: wav.empty? ? "audio/silk" : "audio/wav", size: body.bytesize }
            when :file
              return nil if url.empty?

              body = download_attachment(url, limit: MAX_MEDIA_DOWNLOAD_BYTES) or return nil
              saved = Clacky::Utils::FileProcessor.save(body: body, filename: filename || "file")
              { type: :file, name: saved[:name], path: saved[:path], url: url,
                size: body.bytesize, mime_type: guess_doc_mime(saved[:name]) }
            end
          rescue => e
            Clacky::Logger.warn("[qq] attachment download failed: #{e.message}")
            nil
          end

          # Fetch an attachment URL with a hard size cap. Returns the body String
          # or nil when unavailable/too large. Uses stdlib net/http only and
          # follows up to 4 redirects.
          private def download_attachment(url, limit:)
            uri = URI(url)
            raise "unsupported url" unless uri.is_a?(URI::HTTP)

            redirects = 0
            loop do
              req = Net::HTTP::Get.new(uri)
              req["User-Agent"] = "Clacky-QQBot"
              http = Net::HTTP.new(uri.host, uri.port)
              http.use_ssl = uri.scheme == "https"
              http.open_timeout = 10
              http.read_timeout = 30
              body = +""
              too_big = false
              # The request block yields the response; read_body then streams
              # chunks so the size cap is enforced without buffering it all.
              resp = http.request(req) do |res|
                if res.is_a?(Net::HTTPSuccess)
                  res.read_body do |chunk|
                    body << chunk
                    too_big = true if body.bytesize > limit
                  end
                end
              end
              if resp.is_a?(Net::HTTPRedirection) && resp["location"]
                redirects += 1
                raise "too many redirects" if redirects > 4

                uri = URI.join(uri, resp["location"])
                raise "unsupported redirect" unless uri.is_a?(URI::HTTP)

                next
              end
              raise "HTTP #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)
              raise "attachment too large (> #{limit / 1024 / 1024}MB)" if too_big

              return body
            end
          end

          # QQ uses non-standard content_type tokens for non-image media.
          private def classify_attachment(ctype)
            c = ctype.to_s.downcase
            return :image if c.start_with?("image/")
            return :video if c.start_with?("video/")
            return :voice if c == "voice" || c.start_with?("audio/")

            # Fall back to filename for anything unlabelled.
            :file
          end

          private def normalized_image_mime(ctype)
            ctype.to_s.empty? ? "image/jpeg" : ctype.to_s.downcase
          end

          private def guess_doc_mime(filename)
            case File.extname(filename.to_s).downcase
            when ".pdf" then "application/pdf"
            when ".doc" then "application/msword"
            when ".txt" then "text/plain"
            else "application/octet-stream"
            end
          end

          # Collect ASR hints from top-level and quoted attachments.
          private def extract_asr(data)
            list = Array(data["attachments"]).dup
            Array(data["msg_elements"]).each do |el|
              list.concat(Array(el["attachments"])) if el.is_a?(Hash)
            end
            list.map { |a| a["asr_refer_text"].to_s.strip }.reject(&:empty?).first.to_s
          end

          private def parse_chat_id(chat_id)
            s = chat_id.to_s
            if s.include?(":")
              scope, openid = s.split(":", 2)
              [scope, openid]
            else
              # Bare id — assume group.
              ["group", s]
            end
          end

          private def next_seq
            @msg_seq += 1
          end

          private def parse_time(value)
            return Time.now if value.nil? || value.to_s.empty?

            Time.parse(value.to_s)
          rescue ArgumentError
            Time.now
          end

          private def split_message(text)
            return [] if text.nil? || text.empty?
            return [text] if text.length <= MAX_MESSAGE_CHARS

            chunks    = []
            remaining = text.dup
            while remaining.length > MAX_MESSAGE_CHARS
              window = remaining[0, MAX_MESSAGE_CHARS]
              cut = window.rindex("\n\n") || window.rindex("\n") || window.rindex(" ") || MAX_MESSAGE_CHARS
              cut = MAX_MESSAGE_CHARS if cut.zero?
              chunks << remaining[0, cut].rstrip
              remaining = remaining[cut..].lstrip
            end
            chunks << remaining unless remaining.empty?
            chunks
          end
        end

        Adapters.register(:qq, Adapter)
      end
    end
  end
end
