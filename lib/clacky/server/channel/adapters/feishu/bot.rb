# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "json"
require "uri"

module Clacky
  module Channel
    module Adapters
      module Feishu
        # Raised when the app lacks read permission for a specific Feishu document (error code 91403).
        # The user needs to add the app as a collaborator on the document.
        class FeishuDocPermissionError < StandardError
          attr_reader :doc_token

          def initialize(doc_token)
            @doc_token = doc_token
            super("App has no permission to access document: #{doc_token}")
          end
        end

        # Raised when the app hasn't been granted the API scope for documents (error code 99991672).
        # The admin needs to approve the scope via the returned auth_url.
        class FeishuDocScopeError < StandardError
          attr_reader :auth_url

          def initialize(auth_url)
            @auth_url = auth_url
            super("App is missing docx API scope")
          end
        end

        # Raised when any API call fails with 99991672 (missing app scope).
        # The admin needs to open auth_url to grant the required permissions.
        class FeishuScopeError < StandardError
          attr_reader :auth_url, :required_scopes

          def initialize(auth_url, required_scopes: [])
            @auth_url = auth_url
            @required_scopes = required_scopes
            super("App is missing required API scope")
          end
        end

        # Feishu Bot API client.
        # Handles authentication, message sending, and API calls.
        class Bot
          API_TIMEOUT = 10
          DOWNLOAD_TIMEOUT = 60
          ERR_SCOPE_MISSING = 99991672
          ERR_SCOPE_MISSING_2 = 230027
          ERR_INVALID_TOKEN = 99991663
          GROUP_HISTORY_LIMIT = 15
          SCOPE_GROUP_MSG = "im:message.group_msg"
          CARDKIT_CONTENT_ELEMENT_ID = "content"
          CARDKIT_STATUS_ELEMENT_ID = "status"
          CARDKIT_TERMINAL_STATUS_TEXT = {
            waiting: "Waiting for input",
            success: "Done",
            failed: "Failed",
            interrupted: "Stopped"
          }.freeze
          CARDKIT_TERMINAL_STATES = CARDKIT_TERMINAL_STATUS_TEXT.keys.freeze
          CARDKIT_SUMMARY_MAX_LENGTH = 50
          ProgressCardSession = Struct.new(:card_id, :sequence, :closed, :mutex)

          def initialize(app_id:, app_secret:, domain: DEFAULT_DOMAIN)
            @app_id = app_id
            @app_secret = app_secret
            @domain = domain
            @token_cache = nil
            @token_expires_at = nil
            @progress_cards = {}
            @progress_cards_mutex = Mutex.new

          end

          # Send plain text message
          # @param chat_id [String] Chat ID (open_chat_id)
          # @param text [String] Message text
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] Response with :message_id
          def send_text(chat_id, text, reply_to: nil)
            content, msg_type = build_message_payload(text)
            payload = {
              receive_id: chat_id,
              msg_type: msg_type,
              content: content
            }
            payload[:reply_to_message_id] = reply_to if reply_to

            response = post("/open-apis/im/v1/messages", payload, params: { receive_id_type: "chat_id" })

            code = response["code"]
            if code != 0
              Clacky::Logger.warn("[feishu] send_text failed",
                code: code, msg: response["msg"],
                chat_id: chat_id, msg_type: msg_type)
            end

            { message_id: response.dig("data", "message_id") }
          end

          # Update an existing message
          # @param message_id [String] Message ID to update
          # @param text [String] New text content
          # @return [Boolean] Success status
          def update_message(message_id, text)
            content, msg_type = build_message_payload(text)
            payload = {
              msg_type: msg_type,
              content: content
            }

            response = patch("/open-apis/im/v1/messages/#{message_id}", payload)
            response["code"] == 0
          rescue => e
            Clacky::Logger.warn("[feishu] Failed to update message: #{e.message}")
            false
          end

          # Create and send a CardKit card used for low-frequency task progress.
          # @return [Hash] Response with :message_id and opaque :progress_id
          def send_progress_card(chat_id, text, reply_to: nil, state: :running)
            create_response = post("/open-apis/cardkit/v1/cards", {
              type: "card_json",
              data: build_progress_card_payload(text)
            })
            unless create_response["code"] == 0
              raise "Failed to create progress card: code=#{create_response["code"]} msg=#{create_response["msg"]}"
            end

            card_id = create_response.dig("data", "card_id").to_s
            raise "Failed to create progress card: no card_id returned" if card_id.empty?

            content = JSON.generate({ type: "card", data: { card_id: card_id } })
            if reply_to
              response = post("/open-apis/im/v1/messages/#{reply_to}/reply", {
                msg_type: "interactive",
                content: content
              })
            else
              response = post("/open-apis/im/v1/messages", {
                receive_id: chat_id,
                msg_type: "interactive",
                content: content
              }, params: { receive_id_type: "chat_id" })
            end
            unless response["code"] == 0
              raise "Failed to send progress card: code=#{response["code"]} msg=#{response["msg"]}"
            end

            message_id = response.dig("data", "message_id").to_s
            session = ProgressCardSession.new(card_id, 1, false, Mutex.new)
            @progress_cards_mutex.synchronize { @progress_cards[card_id] = session }

            { message_id: message_id, progress_id: card_id }
          end

          # Update or finalize a CardKit progress card.
          # @return [Boolean] Success status
          def update_progress_card(progress_id, text, state: :running)
            session = @progress_cards_mutex.synchronize { @progress_cards[progress_id] }
            return false unless session

            terminal = CARDKIT_TERMINAL_STATES.include?(state.to_sym)
            session.mutex.synchronize do
              return false if session.closed

              if terminal
                finalize_progress_card(session, text, state)
              else
                update_progress_card_status(session, text)
              end
            end
          rescue => e
            Clacky::Logger.warn("[feishu] Failed to update progress card: #{e.message}")
            false
          end

          # Upload a local file to Feishu and send it to a chat.
          # Images use /im/v1/images + msg_type "image".
          # All other files use /im/v1/files + msg_type "file".
          # @param chat_id [String] Chat ID
          # @param path [String] Local file path
          # @param name [String, nil] Display filename
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] Response with :message_id
          def send_file(chat_id, path, name: nil, reply_to: nil)
            raise ArgumentError, "File not found: #{path}" unless File.exist?(path)

            # Always derive filename from the real path for type detection and upload.
            # The `name` param (often markdown alt text) may lack an extension,
            # causing images to be mis-detected as generic files.
            filename  = File.basename(path)
            file_data = File.binread(path)
            ext       = File.extname(filename).downcase

            if %w[.jpg .jpeg .png .gif .webp].include?(ext)
              image_key = upload_image(file_data, filename)
              content   = JSON.generate({ image_key: image_key })
              msg_type  = "image"
            else
              file_key = upload_file(file_data, filename)
              content  = JSON.generate({ file_key: file_key })
              msg_type = "file"
            end

            payload = { receive_id: chat_id, msg_type: msg_type, content: content }
            payload[:reply_to_message_id] = reply_to if reply_to

            response = post("/open-apis/im/v1/messages", payload, params: { receive_id_type: "chat_id" })
            { message_id: response.dig("data", "message_id") }
          end

          # Download a message resource (image or file) from Feishu.
          # For message attachments, must use messageResource API — not im/v1/images.
          # @param message_id [String] Message ID containing the resource
          # @param file_key [String] Resource key (image_key or file_key from message content)
          # @param type [String] "image" or "file"
          # @return [Hash] { body: String, content_type: String }
          def download_message_resource(message_id, file_key, type: "image")
            conn = Faraday.new(url: @domain) do |f|
              f.options.timeout = DOWNLOAD_TIMEOUT
              f.options.open_timeout = API_TIMEOUT
              f.ssl.verify = false
              f.adapter Faraday.default_adapter
            end
            response = conn.get("/open-apis/im/v1/messages/#{message_id}/resources/#{file_key}") do |req|
              req.headers["Authorization"] = "Bearer #{tenant_access_token}"
              req.params["type"] = type
            end

            unless response.success?
              raise "Failed to download message resource: HTTP #{response.status}"
            end

            {
              body: response.body,
              content_type: response.headers["content-type"].to_s.split(";").first.strip
            }
          end

          # Fetch the plain-text content of a Feishu document (docx / docs / wiki).
          # Raises FeishuDocPermissionError (code 91403) when the app has no access.
          # @param url [String] Feishu document URL
          # @return [String] Document plain text
          def fetch_doc_content(url)
            doc_token, doc_type = parse_doc_url(url)
            raise ArgumentError, "Unsupported Feishu doc URL: #{url}" unless doc_token

            if doc_type == :wiki
              # Wiki: first resolve the real docToken via get_node
              node = fetch_wiki_node(doc_token)
              actual_token = node["obj_token"]
              actual_type  = node["obj_type"]   # "docx" / "doc" / etc.
              raise "Unsupported wiki node type: #{actual_type}" unless %w[docx doc].include?(actual_type)
              fetch_docx_raw_content(actual_token)
            else
              fetch_docx_raw_content(doc_token)
            end
          end


          # Build message content and type based on text content.
          # Uses interactive card (schema 2.0) for code blocks and tables,
          # post/md for everything else.
          # @param text [String]
          # @return [Array<String, String>] [content_json, msg_type]
          def build_message_payload(text)
            if has_code_block_or_table?(text)
              safe_text = sanitize_images_for_card(text)
              content = JSON.generate({
                schema: "2.0",
                config: { wide_screen_mode: true },
                body: { elements: [{ tag: "markdown", content: safe_text }] }
              })
              [content, "interactive"]
            else
              safe_text = sanitize_images_for_card(text)
              content = JSON.generate({
                zh_cn: { content: [[{ tag: "md", text: safe_text }]] }
              })
              [content, "post"]
            end
          end

          # Build a CardKit schema 2.0 card with native streaming enabled.
          # @return [String] JSON-encoded card content
          def build_progress_card_payload(text)
            JSON.generate({
              schema: "2.0",
              config: {
                streaming_mode: true,
                summary: { content: "[Generating...]" },
                streaming_config: {
                  print_frequency_ms: { default: 50 },
                  print_step: { default: 1 }
                }
              },
              body: {
                elements: [
                  { tag: "markdown", content: "", element_id: CARDKIT_CONTENT_ELEMENT_ID },
                  {
                    tag: "markdown",
                    content: progress_status_markdown(text),
                    element_id: CARDKIT_STATUS_ELEMENT_ID
                  }
                ]
              }
            })
          end

          private def update_progress_card_status(session, text)
            response = perform_cardkit_request("update progress status", session.card_id) do
              put_card_element_content(
                session,
                CARDKIT_STATUS_ELEMENT_ID,
                progress_status_markdown(text)
              )
            end
            response["code"] == 0
          end

          private def finalize_progress_card(session, text, state)
            safe_text = sanitize_images_for_card(text.to_s)
            status_text = CARDKIT_TERMINAL_STATUS_TEXT.fetch(state.to_sym)
            perform_cardkit_request("write final progress status", session.card_id) do
              put_card_element_content(
                session,
                CARDKIT_STATUS_ELEMENT_ID,
                progress_status_markdown(status_text)
              )
            end

            content_response = perform_cardkit_request("write final progress content", session.card_id) do
              put_card_element_content(session, CARDKIT_CONTENT_ELEMENT_ID, safe_text)
            end

            perform_cardkit_request("close progress card", session.card_id) do
              close_progress_card(session, safe_text)
            end

            session.closed = true
            @progress_cards_mutex.synchronize { @progress_cards.delete(session.card_id) }

            content_response["code"] == 0
          end

          private def put_card_element_content(session, element_id, content)
            sequence = next_progress_sequence(session)
            put(
              "/open-apis/cardkit/v1/cards/#{session.card_id}/elements/#{element_id}/content",
              {
                content: content,
                sequence: sequence,
                uuid: "u_#{session.card_id}_#{sequence}"
              }
            )
          end

          private def close_progress_card(session, text)
            sequence = next_progress_sequence(session)
            patch("/open-apis/cardkit/v1/cards/#{session.card_id}/settings", {
              settings: JSON.generate({
                config: {
                  streaming_mode: false,
                  summary: { content: truncate_cardkit_summary(text) }
                }
              }),
              sequence: sequence,
              uuid: "c_#{session.card_id}_#{sequence}"
            })
          end

          private def next_progress_sequence(session)
            session.sequence += 1
          end

          private def progress_status_markdown(text)
            "<font color='grey'>#{sanitize_images_for_card(text.to_s)}</font>"
          end

          private def truncate_cardkit_summary(text)
            clean = text.to_s.gsub(/\s+/, " ").strip
            return clean if clean.length <= CARDKIT_SUMMARY_MAX_LENGTH

            "#{clean[0, CARDKIT_SUMMARY_MAX_LENGTH - 3]}..."
          end

          private def perform_cardkit_request(action, card_id)
            response = yield
            unless response["code"] == 0
              Clacky::Logger.warn("[feishu] CardKit #{action} failed",
                code: response["code"], msg: response["msg"], card_id: card_id)
            end
            response
          rescue => e
            Clacky::Logger.warn("[feishu] CardKit #{action} failed",
              error: e.message, card_id: card_id)
            { "code" => -1, "msg" => e.message }
          end

          def has_code_block_or_table?(text)
            text.match?(/```[\s\S]*?```/) || text.match?(/\|.+\|[\r\n]+\|[-:| ]+\|/)
          end

          # Convert Markdown image syntax ![alt](url) to plain links [alt](url)
          # inside interactive card content.  Feishu interactive cards do NOT
          # support image markdown — sending it triggers error 230099 and the
          # entire message is silently dropped.
          #
          # Code blocks are preserved untouched (images inside ``` fences are
          # left as-is since they are literal text, not rendered markdown).
          #
          # This is a pure function with no side effects — thread-safe by design.
          # @param text [String] raw markdown text
          # @return [String] sanitised text safe for interactive cards
          def sanitize_images_for_card(text)
            # Split on code fences to avoid transforming inside code blocks
            parts = text.split(/(```[\s\S]*?```)/)
            parts.map { |segment|
              if segment.start_with?("```")
                segment  # code block — leave untouched
              else
                # ![alt](url) → [alt](url)   (drop the leading !)
                segment.gsub(/!\[([^\]]*)\]\(([^)]+)\)/) do
                  alt, url = Regexp.last_match(1), Regexp.last_match(2)
                  alt.empty? ? url : "[#{alt}](#{url})"
                end
              end
            }.join
          end

          # Fetch recent messages from a chat via the message list API.
          # Returns an array of { user_id, text } hashes, oldest first.
          # @param chat_id [String]
          # @param limit [Integer]
          # @return [Array<Hash>]
          def fetch_chat_history(chat_id, limit: GROUP_HISTORY_LIMIT)
            response = get("/open-apis/im/v1/messages", params: {
              container_id_type: "chat",
              container_id:      chat_id,
              sort_type:         "ByCreateTimeDesc",
              page_size:         limit
            })
            unless response["code"] == 0
              code = response["code"].to_i
              Clacky::Logger.warn("[feishu] fetch_chat_history failed code=#{code} msg=#{response["msg"]}, ext=#{response.dig("error", "message") || response["msg"]}")
              if code == ERR_SCOPE_MISSING || code == ERR_SCOPE_MISSING_2
                auth_url = response.dig("error", "permission_violations", 0, "attach_url") ||
                           extract_url(response["msg"].to_s)
                scopes = (response.dig("error", "permission_violations") || []).map { |v| v["subject"] }.compact
                raise FeishuScopeError.new(auth_url, required_scopes: scopes)
              end
              return []
            end

            items = response.dig("data", "items") || []
            Clacky::Logger.info("[feishu] fetch_chat_history chat=#{chat_id} api_items=#{items.size} first=#{items.first&.inspect}")
            items.reverse.filter_map do |item|
              content = begin
                body = JSON.parse(item.dig("body", "content").to_s)
                body["text"].to_s.gsub(/@_user_\S+\s?/, "").gsub(/@\S+\s?/, "").strip
              rescue JSON::ParserError
                nil
              end
              next if content.nil? || content.empty?

              sender_id = item.dig("sender", "id").to_s
              { user_id: sender_id, text: content }
            end
          rescue FeishuScopeError
            raise
          rescue => e
            Clacky::Logger.warn("[feishu] fetch_chat_history failed: #{e.message}")
            []
          end
          # Used to detect @bot mentions in group chats.
          # @return [String, nil] bot open_id, or nil if the API call fails
          def bot_open_id
            @bot_open_id ||= get("/open-apis/bot/v3/info").dig("bot", "open_id")
          rescue => e
            Clacky::Logger.warn("[feishu] Failed to fetch bot_open_id: #{e.message}")
            nil
          end

          # Get tenant access token (cached)
          # @return [String] Access token
          def tenant_access_token
            return @token_cache if @token_cache && @token_expires_at && Time.now < @token_expires_at

            response = post_without_auth("/open-apis/auth/v3/tenant_access_token/internal", {
              app_id: @app_id,
              app_secret: @app_secret
            })

            raise "Failed to get tenant access token: #{response['msg']}" if response["code"] != 0

            @token_cache = response["tenant_access_token"]
            # Token expires in 2 hours, refresh 5 minutes early
            @token_expires_at = Time.now + (2 * 60 * 60 - 5 * 60)
            @token_cache
          end

          # Make authenticated GET request
          # @param path [String] API path
          # @param params [Hash] Query parameters
          # @return [Hash] Parsed response
          def get(path, params: {})
            with_token_retry do
              conn = build_connection
              response = conn.get(path) do |req|
                req.headers["Authorization"] = "Bearer #{tenant_access_token}"
                req.params.update(params)
              end

              parse_response(response)
            end
          end

          # Make authenticated POST request
          # @param path [String] API path
          # @param body [Hash] Request body
          # @param params [Hash] Query parameters
          # @return [Hash] Parsed response
          def post(path, body, params: {})
            with_token_retry do
              conn = build_connection
              response = conn.post(path) do |req|
                req.headers["Authorization"] = "Bearer #{tenant_access_token}"
                req.headers["Content-Type"] = "application/json"
                req.params.update(params)
                req.body = JSON.generate(body)
              end

              parse_response(response)
            end
          end

          # Make authenticated PUT request
          # @param path [String] API path
          # @param body [Hash] Request body
          # @return [Hash] Parsed response
          def put(path, body)
            with_token_retry do
              conn = build_connection
              response = conn.put(path) do |req|
                req.headers["Authorization"] = "Bearer #{tenant_access_token}"
                req.headers["Content-Type"] = "application/json"
                req.body = JSON.generate(body)
              end

              parse_response(response)
            end
          end

          # Make authenticated PATCH request
          # @param path [String] API path
          # @param body [Hash] Request body
          # @return [Hash] Parsed response
          def patch(path, body)
            with_token_retry do
              conn = build_connection
              response = conn.patch(path) do |req|
                req.headers["Authorization"] = "Bearer #{tenant_access_token}"
                req.headers["Content-Type"] = "application/json"
                req.body = JSON.generate(body)
              end

              parse_response(response)
            end
          end

          # Wrap an authenticated API call. If Feishu reports an invalid or
          # revoked access token (99991663) while it is still inside our cache
          # window, force a token refresh and retry the request once.
          # @return [Hash] Parsed response
          def with_token_retry
            response = yield
            if response.is_a?(Hash) && response["code"] == ERR_INVALID_TOKEN
              Clacky::Logger.warn("[feishu] token invalid (99991663), refreshing and retrying once")
              @token_cache = nil
              @token_expires_at = nil
              response = yield
            end
            response
          end

          # Make POST request without authentication (for token endpoint)
          # @param path [String] API path
          # @param body [Hash] Request body
          # @return [Hash] Parsed response
          def post_without_auth(path, body)
            conn = build_connection
            response = conn.post(path) do |req|
              req.headers["Content-Type"] = "application/json"
              req.body = JSON.generate(body)
            end

            parse_response(response)
          end

          # Upload an image to Feishu and return image_key.
          # @param data [String] Binary file content
          # @param filename [String] Display filename
          # @return [String] image_key
          def upload_image(data, filename)
            conn = Faraday.new(url: @domain) do |f|
              f.options.timeout = DOWNLOAD_TIMEOUT
              f.options.open_timeout = API_TIMEOUT
              f.ssl.verify = false
              f.request :multipart
              f.adapter Faraday.default_adapter
            end

            response = conn.post("/open-apis/im/v1/images") do |req|
              req.headers["Authorization"] = "Bearer #{tenant_access_token}"
              req.body = {
                image_type: "message",
                image: Faraday::Multipart::FilePart.new(
                  StringIO.new(data), detect_mime(filename), filename
                )
              }
            end

            result = JSON.parse(response.body)
            raise "Failed to upload image: code=#{result["code"]} msg=#{result["msg"]}" if result["code"] != 0

            result.dig("data", "image_key") or raise "No image_key returned"
          end

          # Upload a file to Feishu and return file_key.
          # @param data [String] Binary file content
          # @param filename [String] Display filename
          # @return [String] file_key
          def upload_file(data, filename)
            conn = Faraday.new(url: @domain) do |f|
              f.options.timeout = DOWNLOAD_TIMEOUT
              f.options.open_timeout = API_TIMEOUT
              f.ssl.verify = false
              f.request :multipart
              f.adapter Faraday.default_adapter
            end

            response = conn.post("/open-apis/im/v1/files") do |req|
              req.headers["Authorization"] = "Bearer #{tenant_access_token}"
              req.body = {
                file_type: feishu_file_type(filename),
                file_name: filename,
                file: Faraday::Multipart::FilePart.new(
                  StringIO.new(data), detect_mime(filename), filename
                )
              }
            end

            result = JSON.parse(response.body)
            raise "Failed to upload file: code=#{result["code"]} msg=#{result["msg"]}" if result["code"] != 0

            result.dig("data", "file_key") or raise "No file_key returned"
          end

          # Map file extension to Feishu file_type enum.
          # Feishu accepts: opus, mp4, pdf, doc, xls, ppt, stream (others)
          def feishu_file_type(filename)
            case File.extname(filename).downcase
            when ".pdf"             then "pdf"
            when ".doc", ".docx"   then "doc"
            when ".xls", ".xlsx"   then "xls"
            when ".ppt", ".pptx"   then "ppt"
            when ".mp4"            then "mp4"
            when ".opus"           then "opus"
            else                        "stream"
            end
          end

          # Detect MIME type from filename extension.
          def detect_mime(filename)
            case File.extname(filename).downcase
            when ".jpg", ".jpeg" then "image/jpeg"
            when ".png"          then "image/png"
            when ".gif"          then "image/gif"
            when ".webp"         then "image/webp"
            when ".pdf"          then "application/pdf"
            when ".mp4"          then "video/mp4"
            else                      "application/octet-stream"
            end
          end

          # Parse Feishu doc URL and return [doc_token, type]
          # type is :docx, :docs, or :wiki
          # @param url [String]
          # @return [Array<String, Symbol>, nil]
          def parse_doc_url(url)
            if (m = url.match(%r{/(?:docx|docs)/([A-Za-z0-9_-]+)}))
              [m[1], :docx]
            elsif (m = url.match(%r{/wiki/([A-Za-z0-9_-]+)}))
              [m[1], :wiki]
            end
          end

          # Fetch raw text content of a docx document.
          # Raises FeishuDocPermissionError on 91403.
          # @param doc_token [String]
          # @return [String]
          def fetch_docx_raw_content(doc_token)
            response = get("/open-apis/docx/v1/documents/#{doc_token}/raw_content")
            check_doc_error!(response, doc_token)
            response.dig("data", "content").to_s.strip
          end

          # Resolve wiki node to get real obj_token and obj_type.
          # @param wiki_token [String]
          # @return [Hash] node data with "obj_token" and "obj_type"
          def fetch_wiki_node(wiki_token)
            response = get("/open-apis/wiki/v2/spaces/get_node", params: { token: wiki_token, obj_type: "wiki" })
            check_doc_error!(response, wiki_token)
            response.dig("data", "node") or raise "No node in wiki response"
          end

          # Check doc API response for known permission errors and raise accordingly.
          def check_doc_error!(response, token)
            code = response["code"].to_i
            return if code == 0

            if code == 91403
              raise FeishuDocPermissionError, token
            elsif code == ERR_SCOPE_MISSING
              # Extract auth URL from the error message if present
              auth_url = response.dig("error", "permission_violations", 0, "attach_url") ||
                         extract_url(response["msg"].to_s)
              raise FeishuDocScopeError.new(auth_url)
            else
              raise "Failed to fetch doc: code=#{code} msg=#{response["msg"]}"
            end
          end

          private def extract_url(text)
            text[URI::DEFAULT_PARSER.make_regexp(%w[https])]
          end

          # Build Faraday connection
          # @return [Faraday::Connection]
          def build_connection
            Faraday.new(url: @domain) do |f|
              f.options.timeout = API_TIMEOUT
              f.options.open_timeout = API_TIMEOUT
              f.ssl.verify = false
              f.adapter Faraday.default_adapter
            end
          end

          # Parse API response
          # @param response [Faraday::Response]
          # @return [Hash] Parsed JSON
          def parse_response(response)
            # Feishu returns JSON even on 4xx — parse it so callers can inspect error codes
            parsed = JSON.parse(response.body)
            return parsed if response.success? || parsed.key?("code")

            raise "API request failed: HTTP #{response.status} body=#{response.body.to_s[0..300]}"
          rescue JSON::ParserError
            raise "API request failed: HTTP #{response.status} body=#{response.body.to_s[0..300]}"
          end
        end
      end
    end
  end
end
