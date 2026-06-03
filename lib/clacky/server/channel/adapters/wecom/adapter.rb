# frozen_string_literal: true

require_relative "../../adapters/base"
require_relative "ws_client"
require_relative "media_downloader"
require_relative "../feishu/file_processor"

module Clacky
  module Channel
    module Adapters
      module Wecom
        # WeCom (Enterprise WeChat) adapter.
        # Receives messages via WebSocket long connection and sends via bot API.
        class Adapter < Base
          def self.platform_id
            :wecom
          end

          def self.env_keys
            %w[IM_WECOM_BOT_ID IM_WECOM_SECRET]
          end

          def self.platform_config(data)
            {
              bot_id: data["IM_WECOM_BOT_ID"],
              secret: data["IM_WECOM_SECRET"]
            }
          end

          def self.set_env_data(data, config)
            data["IM_WECOM_BOT_ID"] = config[:bot_id]
            data["IM_WECOM_SECRET"] = config[:secret]
          end

          def initialize(config)
            @config = config
            @ws_client = WSClient.new(
              bot_id: config[:bot_id],
              secret: config[:secret],
              ws_url: config[:ws_url] || WSClient::WS_URL
            )
            @running = false
            @on_message = nil
          end

          def start(&on_message)
            @running = true
            @on_message = on_message

            @ws_client.start do |raw|
              handle_raw_message(raw)
            end
          rescue WSClient::AuthError => e
            Clacky::Logger.error("[WecomAdapter] Authentication failed, not retrying: #{e.message}")
          end

          def stop
            @running = false
            @ws_client.stop
          end

          def send_text(chat_id, text, reply_to: nil)
            @ws_client.send_message(chat_id, text)
          end

          def send_file(chat_id, path, name: nil)
            @ws_client.send_file(chat_id, path, name: name)
          end

          def validate_config(config)
            errors = []
            errors << "bot_id is required" if config[:bot_id].nil? || config[:bot_id].empty?
            errors << "secret is required" if config[:secret].nil? || config[:secret].empty?
            errors
          end


          def handle_raw_message(raw)
            msgtype = raw["msgtype"]
            Clacky::Logger.info("[wecom] msgtype=#{msgtype} raw=#{raw.to_s[0..300]}")

            chat_id = raw["chatid"] || raw.dig("from", "userid")
            return unless chat_id

            unless %w[text image file mixed].include?(msgtype)
              @on_message&.call({ type: :message, platform: :wecom, chat_id: chat_id, unsupported: true })
              return
            end

            user_id = raw.dig("from", "userid")
            chat_type = raw["chattype"] == "group" ? :group : :direct
            text  = ""
            files = []

            case msgtype
            when "text"
              text = raw.dig("text", "content").to_s.strip
              return if text.empty?
            when "image"
              file = download_image(raw["image"], chat_id)
              return unless file
              files = [file]
            when "file"
              url      = raw.dig("file", "url")
              aeskey   = raw.dig("file", "aeskey")
              return unless url
              filename = raw.dig("file", "name") || raw.dig("file", "filename") || "attachment"
              result   = MediaDownloader.download(url, aeskey)
              filename = result[:filename] || filename
              saved = Clacky::Utils::FileProcessor.save(body: result[:body], filename: filename)
              files = [saved]
            when "mixed"
              text, files = parse_mixed(raw.dig("mixed", "msg_item") || [], chat_id)
              return if text.empty? && files.empty?
            end

            event = {
              type: :message,
              platform: :wecom,
              chat_id: chat_id,
              user_id: user_id,
              text: text,
              files: files,
              message_id: raw["msgid"],
              timestamp: raw["create_time"] ? Time.at(raw["create_time"]) : Time.now,
              chat_type: chat_type,
              raw: raw
            }

            @on_message&.call(event)
          rescue => e
            Clacky::Logger.error("[WecomAdapter] handle_raw_message error: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
            begin
              @ws_client.send_message(chat_id, "Error processing message: #{e.message}") if chat_id
            rescue
              nil
            end
          end

          private def download_image(image_data, chat_id)
            url    = image_data&.[]("url")
            aeskey = image_data&.[]("aeskey")
            return nil unless url
            result = MediaDownloader.download(url, aeskey)
            mime = MediaDownloader.detect_mime(result[:body])
            if result[:body].bytesize > MAX_IMAGE_BYTES
              @ws_client.send_message(chat_id, "Image too large (#{(result[:body].bytesize / 1024.0).round(0).to_i}KB), max #{MAX_IMAGE_BYTES / 1024}KB")
              return nil
            end
            require "base64"
            data_url = "data:#{mime};base64,#{Base64.strict_encode64(result[:body])}"
            { name: "image.jpg", mime_type: mime, data_url: data_url }
          end

          private def parse_mixed(items, chat_id)
            text_parts = []
            files = []
            items.each do |item|
              case item["msgtype"]
              when "text"
                text_parts << item.dig("text", "content").to_s.strip
              when "image"
                file = download_image(item["image"], chat_id)
                files << file if file
              end
            end
            [text_parts.join("\n").strip, files]
          end

          MAX_IMAGE_BYTES = Clacky::Utils::FileProcessor::MAX_IMAGE_BYTES
        end

        Adapters.register(:wecom, Adapter)
      end
    end
  end
end
