# frozen_string_literal: true

require "json"

module Clacky
  module Channel
    module Adapters
      module Feishu
        # Parses incoming Feishu webhook events into a standardized InboundMessage format.
        class MessageParser
          # Parse a Feishu webhook event body
          # @param body [String, Hash] Raw webhook body
          # @return [Hash, nil] Standardized inbound message, or nil if not a message event
          def self.parse(body)
            data = body.is_a?(Hash) ? body : JSON.parse(body)
            new(data).parse
          rescue JSON::ParserError
            nil
          end

          def initialize(data)
            @data = data
          end

          # @return [Hash, nil] Inbound message or nil
          def parse
            # Handle verification challenge
            if @data["type"] == "url_verification"
              return { type: :challenge, challenge: @data["challenge"] }
            end

            header = @data["header"]
            return nil unless header

            event_type = header["event_type"]

            case event_type
            when "im.message.receive_v1"
              parse_message_event
            else
              nil
            end
          end


          # Parse message.receive event
          # @return [Hash, nil]
          def parse_message_event
            event = @data["event"]
            return nil unless event

            message = event["message"]
            sender = event["sender"]
            return nil unless message && sender

            msg_type = message["message_type"]
            Clacky::Logger.info("[feishu] msg_type=#{msg_type} content=#{message["content"].to_s[0..300]}")
            unless %w[text image file post].include?(msg_type)
              Clacky::Logger.info("[feishu] dropping unsupported msg_type=#{msg_type}")
              return nil
            end

            content_raw = message["content"]
            return nil unless content_raw

            content = JSON.parse(content_raw)
            text = ""
            image_keys = []
            file_attachments = []

            case msg_type
            when "text"
              text = strip_mentions(content["text"].to_s.strip)
              return nil if text.empty?
            when "image"
              image_keys = [content["image_key"]].compact
              return nil if image_keys.empty?
            when "file"
              file_key = content["file_key"]
              file_name = content["file_name"]
              return nil unless file_key
              file_attachments = [{ key: file_key, name: file_name.to_s }]
            when "post"
              parsed = parse_post_content(content)
              text = parsed[:text]
              image_keys = parsed[:image_keys]
              return nil if text.empty? && image_keys.empty?
            end

            chat_id = message["chat_id"]
            message_id = message["message_id"]
            user_id = sender.dig("sender_id", "open_id")
            chat_type = message["chat_type"] == "p2p" ? :direct : :group
            create_time = message["create_time"]&.to_i
            timestamp = create_time ? Time.at(create_time / 1000.0) : Time.now

            {
              type: :message,
              platform: :feishu,
              chat_id: chat_id,
              user_id: user_id,
              text: text,
              image_keys: image_keys,
              file_attachments: file_attachments,
              doc_urls: extract_doc_urls(text),
              message_id: message_id,
              timestamp: timestamp,
              chat_type: chat_type,
              mentioned_open_ids: Array(message["mentions"]).filter_map { |m| m.dig("id", "open_id") },
              raw: @data
            }
          rescue JSON::ParserError
            nil
          end

          # Extract Feishu document URLs from text.
          # Matches: /docx/TOKEN, /docs/TOKEN, /wiki/TOKEN
          # @param text [String]
          # @return [Array<String>] matched URLs
          def extract_doc_urls(text)
            return [] if text.nil? || text.empty?

            text.scan(%r{https?://[a-zA-Z0-9._-]+\.(?:feishu\.cn|larksuite\.com)/(?:docx|docs|wiki)/[A-Za-z0-9_-]+(?:\?[^\s]*)?})
          end

          # Strip bot @mentions from message text
          # @param text [String]
          # @return [String]
          def strip_mentions(text)
            # Feishu mentions are formatted as <at user_id="...">Name</at>
            text.gsub(/<at[^>]*>.*?<\/at>/, "").strip
          end

          # Parse a Feishu post content body into text and image_keys.
          # post content structure from event payloads:
          #   {"title": "", "content": [[{tag, text, ...}, ...], ...]}
          def parse_post_content(content)
            rows = content["content"]
            return { text: "", image_keys: [] } unless rows.is_a?(Array)

            text_lines = []
            image_keys = []

            rows.each do |row|
              next unless row.is_a?(Array)
              line_parts = []
              row.each do |element|
                next unless element.is_a?(Hash)
                case element["tag"]
                when "text", "md", "code_block"
                  part = element["text"].to_s
                  line_parts << part unless part.empty?
                when "a"
                  part = element["text"].to_s
                  part = element["href"].to_s if part.empty?
                  line_parts << part unless part.empty?
                when "img"
                  key = element["image_key"].to_s
                  image_keys << key unless key.empty?
                when "at"
                  # skipped — mention identity resolved via top-level mentions field
                end
              end
              line = line_parts.join.strip
              text_lines << line unless line.empty?
            end

            { text: text_lines.join("\n"), image_keys: image_keys }
          end
        end
      end
    end
  end
end
