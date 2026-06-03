# frozen_string_literal: true

require_relative "../../adapters/base"
require_relative "api_client"
require_relative "gateway_client"
require_relative "../feishu/file_processor"
require "time"

module Clacky
  module Channel
    module Adapters
      module Discord
        # Discord adapter (bot mode).
        # Receives messages via the Gateway WebSocket and sends via the REST API.
        class Adapter < Base
          MAX_IMAGE_BYTES = Clacky::Utils::FileProcessor::MAX_IMAGE_BYTES

          def self.platform_id
            :discord
          end

          def self.env_keys
            %w[IM_DISCORD_BOT_TOKEN]
          end

          def self.platform_config(data)
            {
              bot_token: data["IM_DISCORD_BOT_TOKEN"]
            }
          end

          def self.set_env_data(data, config)
            data["IM_DISCORD_BOT_TOKEN"] = config[:bot_token]
          end

          def self.test_connection(fields)
            bot_token = fields[:bot_token].to_s.strip
            return { ok: false, error: "bot_token is required" } if bot_token.empty?

            client = ApiClient.new(bot_token: bot_token)
            me     = client.me
            if me["id"]
              { ok: true, message: "Connected as #{me["username"]}##{me["discriminator"]} (id=#{me["id"]})" }
            else
              { ok: false, error: "Empty response from /users/@me" }
            end
          rescue ApiClient::ApiError => e
            { ok: false, error: e.message }
          rescue StandardError => e
            { ok: false, error: e.message }
          end

          def initialize(config)
            @config       = config
            @bot_token    = config[:bot_token]
            @api          = ApiClient.new(bot_token: @bot_token)
            @gateway      = GatewayClient.new(bot_token: @bot_token)
            @bot_user_id  = nil
            @running      = false
            @on_message   = nil
          end

          def start(&on_message)
            @running    = true
            @on_message = on_message

            begin
              me = @api.me
              @bot_user_id = me["id"]
              Clacky::Logger.info("[DiscordAdapter] authenticated as #{me["username"]} (id=#{@bot_user_id})")
            rescue ApiClient::ApiError => e
              Clacky::Logger.error("[DiscordAdapter] /users/@me failed, not retrying: #{e.message}")
              return
            end

            @gateway.start do |evt|
              handle_gateway_event(evt)
            end
          rescue GatewayClient::AuthError => e
            Clacky::Logger.error("[DiscordAdapter] Authentication failed, not retrying: #{e.message}")
          end

          def stop
            @running = false
            @gateway.stop
          end

          def send_text(chat_id, text, reply_to: nil)
            res = @api.send_message(chat_id, text, reply_to: reply_to)
            { message_id: res["id"] }
          rescue ApiClient::ApiError => e
            Clacky::Logger.error("[DiscordAdapter] send_text failed: #{e.message}")
            { message_id: nil }
          end

          def update_message(chat_id, message_id, text)
            @api.edit_message(chat_id, message_id, text)
            true
          rescue ApiClient::ApiError => e
            Clacky::Logger.warn("[DiscordAdapter] update_message failed: #{e.message}")
            false
          end

          def supports_message_updates?
            true
          end

          def send_file(chat_id, path, name: nil)
            @api.send_file(chat_id, path, name: name)
          rescue ApiClient::ApiError => e
            Clacky::Logger.error("[DiscordAdapter] send_file failed: #{e.message}")
            nil
          end

          def validate_config(config)
            errors = []
            errors << "bot_token is required" if config[:bot_token].nil? || config[:bot_token].empty?
            errors
          end

          private def handle_gateway_event(evt)
            return unless evt[:type] == :message
            handle_message(evt[:data])
          end

          private def handle_message(msg)
            return if msg.nil?
            author = msg["author"] || {}

            return if author["bot"] == true
            return if @bot_user_id && author["id"] == @bot_user_id

            chat_id   = msg["channel_id"]
            return unless chat_id

            user_id   = author["id"]
            chat_type = msg["guild_id"] ? :group : :direct
            mentioned_ids = Array(msg["mentions"]).map { |m| m["id"] }

            if chat_type == :group
              if @bot_user_id.nil?
                Clacky::Logger.warn("[DiscordAdapter] bot_user_id unavailable; dropping group message")
                return
              end
              unless mentioned_ids.include?(@bot_user_id)
                @on_message&.call(event.merge(observe_only: true))
                return
              end
            end

            allowed_users = @config[:allowed_users]
            if allowed_users && !allowed_users.empty?
              return unless allowed_users.include?(user_id)
            end

            text  = strip_bot_mention(msg["content"].to_s, @bot_user_id)
            files = process_attachments(Array(msg["attachments"]), chat_id)

            if text.strip.empty? && files.empty?
              @on_message&.call({ type: :message, platform: :discord, chat_id: chat_id, unsupported: true })
              return
            end

            event = {
              type: :message,
              platform: :discord,
              chat_id: chat_id,
              user_id: user_id,
              text: text,
              files: files,
              message_id: msg["id"],
              timestamp: parse_timestamp(msg["timestamp"]),
              chat_type: chat_type,
              mentioned_user_ids: mentioned_ids,
              raw: msg
            }

            @on_message&.call(event)
          rescue => e
            Clacky::Logger.error("[DiscordAdapter] handle_message error: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
            begin
              chat_id ||= msg && msg["channel_id"]
              @api.send_message(chat_id, "Error processing message: #{e.message}") if chat_id
            rescue
              nil
            end
          end

          private def strip_bot_mention(text, bot_id)
            return text if bot_id.nil? || text.empty?
            text.gsub(/<@!?#{Regexp.escape(bot_id)}>/, "").strip
          end

          private def process_attachments(attachments, chat_id)
            files = []
            attachments.each do |att|
              url      = att["url"]
              filename = att["filename"] || "attachment"
              next unless url

              result = @api.download(url)
              body   = result[:body]
              mime   = att["content_type"] || result[:content_type]

              if mime && mime.start_with?("image/")
                if body.bytesize > MAX_IMAGE_BYTES
                  @api.send_message(chat_id, "Image too large (#{(body.bytesize / 1024.0).round(0).to_i}KB), max #{MAX_IMAGE_BYTES / 1024}KB")
                  next
                end
                require "base64"
                data_url = "data:#{mime};base64,#{Base64.strict_encode64(body)}"
                files << { name: filename, mime_type: mime, data_url: data_url }
              else
                files << Clacky::Utils::FileProcessor.save(body: body, filename: filename)
              end
            end
            files
          rescue => e
            Clacky::Logger.warn("[DiscordAdapter] process_attachments error: #{e.message}")
            files
          end

          private def parse_timestamp(iso)
            return Time.now if iso.nil? || iso.empty?
            Time.iso8601(iso)
          rescue ArgumentError
            Time.now
          end
        end

        Adapters.register(:discord, Adapter)
      end
    end
  end
end
