# frozen_string_literal: true

require "base64"
require_relative "../../adapters/base"
require_relative "api_client"

module Clacky
  module Channel
    module Adapters
      module Telegram
        # Telegram Bot API adapter.
        #
        # Transport: HTTPS long-poll via getUpdates (no public domain required).
        # Auth:      single bot token obtained from @BotFather.
        # Group rule: bots only react when @-mentioned or replied to (matches Feishu).
        #
        # Config keys (channels.yml `telegram`):
        #   bot_token       String  required — from @BotFather
        #   base_url        String  default "https://api.telegram.org"
        #                            (override for self-hosted Bot API / proxy)
        #   parse_mode      String  default "Markdown" — set "" / nil to disable
        #   allowed_users   Array   optional whitelist of from.id (numeric, as String)
        class Adapter < Base
          # Telegram messages cap at 4096 UTF-16 code units; we leave a small margin.
          MAX_MESSAGE_CHARS = 4000

          MAX_IMAGE_BYTES = Clacky::Utils::FileProcessor::MAX_IMAGE_BYTES

          def self.platform_id
            :telegram
          end

          def self.env_keys
            %w[IM_TELEGRAM_BOT_TOKEN IM_TELEGRAM_BASE_URL IM_TELEGRAM_PARSE_MODE IM_TELEGRAM_ALLOWED_USERS]
          end

          def self.platform_config(data)
            {
              bot_token:     data["IM_TELEGRAM_BOT_TOKEN"] || data["bot_token"],
              base_url:      data["IM_TELEGRAM_BASE_URL"]  || data["base_url"]   || ApiClient::DEFAULT_BASE_URL,
              parse_mode:    data.key?("parse_mode") ? data["parse_mode"] : (data["IM_TELEGRAM_PARSE_MODE"] || "Markdown"),
              allowed_users: (data["IM_TELEGRAM_ALLOWED_USERS"] || data["allowed_users"] || "")
                               .then { |v| v.is_a?(Array) ? v : v.to_s.split(",").map(&:strip).reject(&:empty?) }
            }.compact
          end

          def self.set_env_data(data, config)
            data["IM_TELEGRAM_BOT_TOKEN"]      = config[:bot_token]
            data["IM_TELEGRAM_BASE_URL"]       = config[:base_url]    if config[:base_url]
            data["IM_TELEGRAM_PARSE_MODE"]     = config[:parse_mode]  if config[:parse_mode]
            data["IM_TELEGRAM_ALLOWED_USERS"]  = Array(config[:allowed_users]).join(",")
          end

          # Verify credentials by calling getMe.
          # @param fields [Hash] symbol-keyed credential fields
          # @return [Hash] { ok: Boolean, message:/error: String }
          def self.test_connection(fields)
            token = fields[:bot_token].to_s.strip
            return { ok: false, error: "bot_token is required" } if token.empty?

            base_url = fields[:base_url].to_s.strip
            base_url = ApiClient::DEFAULT_BASE_URL if base_url.empty?

            client = ApiClient.new(token: token, base_url: base_url)
            me     = client.post("getMe", {})
            { ok: true, message: "Connected — bot @#{me["username"]} (id #{me["id"]})" }
          rescue StandardError => e
            { ok: false, error: e.message }
          end

          def initialize(config)
            @config        = config
            @token         = config[:bot_token].to_s
            @base_url      = config[:base_url] || ApiClient::DEFAULT_BASE_URL
            @parse_mode    = config.key?(:parse_mode) ? config[:parse_mode] : "Markdown"
            @parse_mode    = nil if @parse_mode.to_s.empty?
            @allowed_users = Array(config[:allowed_users]).map(&:to_s)

            @api          = ApiClient.new(token: @token, base_url: @base_url)
            @running      = false
            @on_message   = nil
            @last_offset  = nil

            # Cached bot identity (used for @-mention check in groups).
            @bot_username = nil
            @bot_id       = nil
          end

          # ── Lifecycle ──────────────────────────────────────────────────────

          def start(&on_message)
            @running    = true
            @on_message = on_message

            ensure_bot_identity

            Clacky::Logger.info("[TelegramAdapter] starting long-poll (base_url=#{@base_url})")

            consecutive_errors = 0
            while @running
              begin
                updates = @api.get_updates(offset: @last_offset)
                consecutive_errors = 0

                updates.each do |update|
                  @last_offset = update["update_id"] + 1
                  process_update(update)
                rescue => e
                  Clacky::Logger.warn("[TelegramAdapter] process_update error: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
                end
              rescue ApiClient::TimeoutError
                # Long-poll cycle ended with no updates — just loop.
              rescue ApiClient::ApiError => e
                consecutive_errors += 1
                Clacky::Logger.warn("[TelegramAdapter] API #{e.code}: #{e.description}")
                sleep(consecutive_errors > 3 ? 30 : 5)
              rescue => e
                consecutive_errors += 1
                Clacky::Logger.error("[TelegramAdapter] poll error: #{e.message}")
                break unless @running
                sleep(consecutive_errors > 3 ? 30 : 5)
              end
            end
          end

          def stop
            @running = false
          end

          # ── Outbound (called by ChannelUIController) ────────────────────────

          # Send a text message. Splits content longer than Telegram's 4096-char
          # cap into multiple consecutive messages. Returns { message_id: } of
          # the LAST chunk (matches the contract used by the other adapters).
          def send_text(chat_id, text, reply_to: nil)
            chunks = split_message(text.to_s)
            return { message_id: nil } if chunks.empty?

            last_message_id = nil
            chunks.each_with_index do |chunk, i|
              params = {
                chat_id:                  chat_id.to_s,
                text:                     chunk,
                disable_web_page_preview: true
              }
              params[:parse_mode]          = @parse_mode if @parse_mode
              params[:reply_to_message_id] = reply_to.to_i if reply_to && i == 0
              msg = @api.post("sendMessage", params)
              last_message_id = msg["message_id"]
            end
            { message_id: last_message_id }
          rescue ApiClient::ApiError => e
            # Markdown parse failures fall back to plain text — most common cause
            # is unescaped Markdown reserved chars in the agent's output.
            if @parse_mode && e.description.to_s =~ /can't parse entities|markdown/i
              Clacky::Logger.warn("[TelegramAdapter] parse_mode failed, retrying as plain text: #{e.description}")
              fallback = {
                chat_id:                  chat_id.to_s,
                text:                     text.to_s,
                disable_web_page_preview: true
              }
              fallback[:reply_to_message_id] = reply_to.to_i if reply_to
              msg = @api.post("sendMessage", fallback)
              return { message_id: msg["message_id"] }
            end
            Clacky::Logger.error("[TelegramAdapter] send_text failed: #{e.message}")
            { message_id: nil }
          rescue => e
            Clacky::Logger.error("[TelegramAdapter] send_text failed: #{e.message}")
            { message_id: nil }
          end

          def send_file(chat_id, path, name: nil, reply_to: nil)
            return { message_id: nil } unless File.exist?(path)

            is_image = path.to_s.downcase.match?(/\.(png|jpe?g|gif|webp)\z/)
            msg = if is_image
                    @api.send_photo(
                      chat_id:             chat_id.to_s,
                      photo_path:          path,
                      reply_to_message_id: reply_to&.to_i
                    )
                  else
                    @api.send_document(
                      chat_id:             chat_id.to_s,
                      document_path:       path,
                      filename:            name,
                      reply_to_message_id: reply_to&.to_i
                    )
                  end
            { message_id: msg["message_id"] }
          rescue => e
            Clacky::Logger.error("[TelegramAdapter] send_file failed for #{path}: #{e.message}")
            { message_id: nil }
          end

          def update_message(chat_id, message_id, text)
            @api.edit_message_text(
              chat_id:    chat_id.to_s,
              message_id: message_id.to_i,
              text:       text,
              parse_mode: @parse_mode
            )
            true
          rescue => e
            Clacky::Logger.warn("[TelegramAdapter] update_message failed: #{e.message}")
            false
          end

          def supports_message_updates?
            true
          end

          def validate_config(config)
            errors = []
            errors << "bot_token is required" if config[:bot_token].nil? || config[:bot_token].to_s.strip.empty?
            errors
          end

          # ── Inbound ─────────────────────────────────────────────────────────

          def ensure_bot_identity
            me = @api.post("getMe", {})
            @bot_id       = me["id"]
            @bot_username = me["username"]
            Clacky::Logger.info("[TelegramAdapter] bot identity: @#{@bot_username} (id=#{@bot_id})")
          rescue => e
            Clacky::Logger.warn("[TelegramAdapter] getMe failed: #{e.message} — group @-mentions will be dropped")
          end

          def process_update(update)
            msg = update["message"]
            return unless msg

            chat = msg["chat"] || {}
            from = msg["from"] || {}
            chat_id = chat["id"]
            user_id = from["id"]
            return unless chat_id && user_id

            chat_type = chat["type"].to_s
            is_group  = %w[group supergroup].include?(chat_type)
            text      = msg["text"].to_s

            if is_group
              unless group_mention?(msg, text)
                observe_text = text.strip
                unless observe_text.empty?
                  @on_message&.call({ type: :message, platform: :telegram, chat_id: chat_id.to_s, user_id: user_id.to_s, text: observe_text, observe_only: true })
                end
                return
              end
              text = strip_bot_mention(text)
            end

            if @allowed_users.any? && !@allowed_users.include?(user_id.to_s)
              Clacky::Logger.debug("[TelegramAdapter] ignoring message from #{user_id} (not in allowed_users)")
              return
            end

            files = collect_files(msg)
            caption = msg["caption"].to_s
            text = caption if text.empty? && !caption.empty?

            if text.strip.empty? && files.empty?
              @on_message&.call({ type: :message, platform: :telegram, chat_id: chat_id.to_s, unsupported: true })
              return
            end

            event = {
              type:       :message,
              platform:   :telegram,
              chat_id:    chat_id.to_s,
              user_id:    user_id.to_s,
              text:       text.strip,
              files:      files,
              message_id: msg["message_id"].to_s,
              timestamp:  msg["date"] ? Time.at(msg["date"]) : Time.now,
              chat_type:  is_group ? :group : :direct,
              raw:        msg
            }

            Clacky::Logger.info("[TelegramAdapter] msg from #{user_id} in #{chat_id} (#{chat_type}): #{text.slice(0, 80)}")
            @on_message&.call(event)
          end

          # The bot reacts to a group message only if:
          #   1. text contains @<bot_username> as a mention entity, or
          #   2. the message is a reply to a message authored by the bot
          # Fail closed when bot identity is unknown — drop the message rather
          # than respond to every line and spam the group.
          def group_mention?(msg, text)
            return false unless @bot_id

            reply = msg["reply_to_message"]
            return true if reply && reply.dig("from", "id") == @bot_id

            entities = msg["entities"] || []
            entities.any? do |e|
              e["type"] == "mention" &&
                text[e["offset"], e["length"]].to_s.casecmp?("@#{@bot_username}")
            end
          end

          def strip_bot_mention(text)
            return text unless @bot_username
            text.gsub(/@#{Regexp.escape(@bot_username)}\b/i, "").strip
          end

          # Build file-attachment hashes for the agent's vision / file pipeline.
          def collect_files(msg)
            files = []

            if msg["photo"].is_a?(Array) && !msg["photo"].empty?
              # `photo` is an array of size variants — pick the largest.
              largest = msg["photo"].max_by { |p| p["file_size"].to_i }
              begin
                raw = @api.download_file(largest["file_id"])
                if raw.bytesize > MAX_IMAGE_BYTES
                  Clacky::Logger.warn("[TelegramAdapter] image too large (#{raw.bytesize}B), dropping")
                else
                  mime = detect_image_mime(raw)
                  files << {
                    type:      :image,
                    name:      "image.jpg",
                    mime_type: mime,
                    data_url:  "data:#{mime};base64,#{Base64.strict_encode64(raw)}"
                  }
                end
              rescue => e
                Clacky::Logger.warn("[TelegramAdapter] image download failed: #{e.message}")
              end
            end

            if (doc = msg["document"])
              begin
                raw      = @api.download_file(doc["file_id"])
                filename = doc["file_name"].to_s
                filename = "attachment" if filename.empty?
                saved    = Clacky::Utils::FileProcessor.save(body: raw, filename: filename)
                files << { type: :file, name: saved[:name], path: saved[:path] }
              rescue => e
                Clacky::Logger.warn("[TelegramAdapter] document download failed: #{e.message}")
              end
            end

            files
          end

          def detect_image_mime(bytes)
            return "image/jpeg" unless bytes && bytes.bytesize >= 4
            head = bytes.byteslice(0, 8).bytes
            return "image/png"  if head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47
            return "image/gif"  if head[0] == 0x47 && head[1] == 0x49 && head[2] == 0x46
            return "image/webp" if head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 && head[3] == 0x46
            "image/jpeg"
          end

          # ── Helpers ─────────────────────────────────────────────────────────

          # Split text at Telegram's 4096-char cap (we use 4000 as a margin).
          # Prefers paragraph / line / space boundaries; hard-cuts as a last resort.
          def split_message(text)
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

        Adapters.register(:telegram, Adapter)
      end
    end
  end
end
