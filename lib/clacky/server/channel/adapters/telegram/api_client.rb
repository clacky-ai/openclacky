# frozen_string_literal: true

require "json"
require "net/http"
require "net/https"
require "openssl"
require "securerandom"
require "uri"

module Clacky
  module Channel
    module Adapters
      module Telegram
        # Telegram Bot API HTTP client.
        # Spec: https://core.telegram.org/bots/api
        #
        # All requests POST JSON to https://<base>/bot<TOKEN>/<method>.
        # File downloads use https://<base>/file/bot<TOKEN>/<file_path>.
        #
        # `base_url` is configurable to allow self-hosted Bot API servers
        # (https://github.com/tdlib/telegram-bot-api), which is the practical
        # escape hatch for users on networks where api.telegram.org is blocked.
        class ApiClient
          DEFAULT_BASE_URL  = "https://api.telegram.org"
          LONG_POLL_TIMEOUT = 25  # seconds; server holds the request open up to this long
          OPEN_TIMEOUT      = 10
          # Read timeout sliced below the long-poll window so the adapter loop
          # notices stop/shutdown between cycles. Disconnecting early just
          # reconnects with the same offset — the server keeps the request
          # open regardless.
          POLL_READ_TIMEOUT = 10

          class ApiError < StandardError
            attr_reader :code, :description
            def initialize(code, description)
              @code = code
              @description = description
              super("Telegram API error #{code}: #{description}")
            end
          end

          class TimeoutError < StandardError; end

          def initialize(token:, base_url: DEFAULT_BASE_URL)
            @token    = token.to_s
            @base_url = (base_url.to_s.empty? ? DEFAULT_BASE_URL : base_url).chomp("/")
          end

          # Long-poll for updates. Returns the raw `result` array (possibly empty).
          # `offset` is the highest update_id + 1 from the previous batch.
          def get_updates(offset: nil, allowed_updates: %w[message])
            params = { timeout: LONG_POLL_TIMEOUT, allowed_updates: allowed_updates }
            params[:offset] = offset if offset
            post("getUpdates", params, read_timeout: POLL_READ_TIMEOUT)
          end

          # Send a plain or Markdown-formatted message. Returns the Message hash.
          def send_message(chat_id:, text:, parse_mode: nil, reply_to_message_id: nil, message_thread_id: nil, disable_web_page_preview: true)
            params = {
              chat_id:                  chat_id,
              text:                     text,
              disable_web_page_preview: disable_web_page_preview
            }
            params[:parse_mode]              = parse_mode          if parse_mode
            params[:reply_to_message_id]     = reply_to_message_id if reply_to_message_id
            params[:message_thread_id]       = message_thread_id   if message_thread_id
            post("sendMessage", params)
          end

          # Edit the text of a previously sent message. Returns the edited Message hash.
          def edit_message_text(chat_id:, message_id:, text:, parse_mode: nil, disable_web_page_preview: true)
            params = {
              chat_id:                  chat_id,
              message_id:               message_id,
              text:                     text,
              disable_web_page_preview: disable_web_page_preview
            }
            params[:parse_mode] = parse_mode if parse_mode
            post("editMessageText", params)
          end

          # Send a chat action (e.g. "typing") — auto-expires after 5s client-side.
          def send_chat_action(chat_id:, action: "typing", message_thread_id: nil)
            params = { chat_id: chat_id, action: action }
            params[:message_thread_id] = message_thread_id if message_thread_id
            post("sendChatAction", params)
          end

          # Send a photo by local file path. Returns the Message hash.
          def send_photo(chat_id:, photo_path:, caption: nil, reply_to_message_id: nil)
            params = { chat_id: chat_id }
            params[:caption]             = caption             if caption
            params[:reply_to_message_id] = reply_to_message_id if reply_to_message_id
            post_multipart("sendPhoto", params, file_field: "photo", file_path: photo_path)
          end

          # Send a document (arbitrary file). Returns the Message hash.
          def send_document(chat_id:, document_path:, filename: nil, caption: nil, reply_to_message_id: nil)
            params = { chat_id: chat_id }
            params[:caption]             = caption             if caption
            params[:reply_to_message_id] = reply_to_message_id if reply_to_message_id
            post_multipart("sendDocument", params, file_field: "document", file_path: document_path, filename: filename)
          end

          # Resolve a file_id to a file_path via getFile, then download the bytes.
          # Returns the raw byte string.
          def download_file(file_id)
            file = post("getFile", { file_id: file_id })
            path = file["file_path"]
            raise ApiError.new(0, "getFile returned no file_path") if path.to_s.empty?

            uri = URI("#{@base_url}/file/bot#{@token}/#{path}")
            http_get_raw(uri)
          end


          def post(method_name, params, read_timeout: 30)
            uri = URI("#{@base_url}/bot#{@token}/#{method_name}")
            http = build_http(uri, read_timeout: read_timeout)

            req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
            req.body = JSON.generate(params)

            res  = http.request(req)
            body = parse_body(res)
            unwrap(body, method_name)
          rescue Net::ReadTimeout, Net::OpenTimeout
            raise TimeoutError, "#{method_name} timed out"
          end

          def post_multipart(method_name, params, file_field:, file_path:, filename: nil)
            uri      = URI("#{@base_url}/bot#{@token}/#{method_name}")
            boundary = "----clacky-tg-#{SecureRandom.hex(8)}"
            body     = String.new(encoding: "BINARY")

            params.each do |k, v|
              body << "--#{boundary}\r\n"
              body << %(Content-Disposition: form-data; name="#{k}"\r\n\r\n)
              body << v.to_s.dup.force_encoding("BINARY")
              body << "\r\n"
            end

            file_bytes = File.binread(file_path)
            body << "--#{boundary}\r\n"
            body << %(Content-Disposition: form-data; name="#{file_field}"; filename="#{filename || File.basename(file_path)}"\r\n)
            body << "Content-Type: #{mime_for(file_path)}\r\n\r\n"
            body << file_bytes
            body << "\r\n--#{boundary}--\r\n"

            http = build_http(uri, read_timeout: 60)
            req  = Net::HTTP::Post.new(uri.request_uri,
                                       "Content-Type" => "multipart/form-data; boundary=#{boundary}")
            req.body = body

            unwrap(parse_body(http.request(req)), method_name)
          end

          def http_get_raw(uri)
            http = build_http(uri, read_timeout: 60)
            res  = http.request(Net::HTTP::Get.new(uri.request_uri))
            unless res.is_a?(Net::HTTPSuccess)
              raise ApiError.new(res.code.to_i, "GET #{uri.path} → HTTP #{res.code}: #{res.body.to_s.slice(0, 200)}")
            end
            res.body
          rescue Net::ReadTimeout, Net::OpenTimeout
            raise TimeoutError, "file download timed out"
          end

          def build_http(uri, read_timeout:)
            http              = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl      = uri.scheme == "https"
            http.verify_mode  = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
            http.open_timeout = OPEN_TIMEOUT
            http.read_timeout = read_timeout
            http
          end

          def parse_body(res)
            JSON.parse(res.body)
          rescue JSON::ParserError
            raise ApiError.new(res.code.to_i, "non-JSON response from Telegram: #{res.body.to_s.slice(0, 200)}")
          end

          def unwrap(body, method_name)
            if body["ok"]
              body["result"]
            else
              raise ApiError.new(body["error_code"].to_i, "#{method_name}: #{body["description"]}")
            end
          end

          def mime_for(path)
            case File.extname(path).downcase
            when ".png"           then "image/png"
            when ".gif"           then "image/gif"
            when ".webp"          then "image/webp"
            when ".jpg", ".jpeg"  then "image/jpeg"
            when ".pdf"           then "application/pdf"
            when ".txt", ".md"    then "text/plain"
            else                       "application/octet-stream"
            end
          end
        end
      end
    end
  end
end
