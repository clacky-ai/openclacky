# frozen_string_literal: true

require_relative "../base"
require_relative "bot"
require_relative "message_parser"
require_relative "ws_client"

module Clacky
  module IM
    module Adapters
      module Feishu
        DEFAULT_DOMAIN = "https://open.feishu.cn"

        # Feishu adapter implementation.
        # Handles message receiving via WebSocket and sending via Bot API.
        class Adapter < Base

          def self.platform_id
            :feishu
          end

          def self.env_keys
            %w[IM_FEISHU_APP_ID IM_FEISHU_APP_SECRET IM_FEISHU_DOMAIN IM_FEISHU_ALLOWED_USERS]
          end

          def self.platform_config(data)
            {
              app_id: data["IM_FEISHU_APP_ID"],
              app_secret: data["IM_FEISHU_APP_SECRET"],
              domain: data["IM_FEISHU_DOMAIN"] || DEFAULT_DOMAIN,
              allowed_users: data["IM_FEISHU_ALLOWED_USERS"]&.split(",")&.map(&:strip)&.reject(&:empty?)
            }
          end

          def self.set_env_data(data, config)
            data["IM_FEISHU_APP_ID"] = config[:app_id]
            data["IM_FEISHU_APP_SECRET"] = config[:app_secret]
            data["IM_FEISHU_DOMAIN"] = config[:domain] if config[:domain]
            data["IM_FEISHU_ALLOWED_USERS"] = Array(config[:allowed_users]).join(",")
          end

          def initialize(config)
            @config = config
            @bot = Bot.new(
              app_id: config[:app_id],
              app_secret: config[:app_secret],
              domain: config[:domain] || DEFAULT_DOMAIN
            )
            @ws_client = nil
            @running = false
          end

          # Start listening for messages via WebSocket
          # @yield [event] Yields standardized inbound messages
          # @return [void]
          def start(&on_message)
            @running = true
            @on_message = on_message

            @ws_client = WSClient.new(
              app_id: @config[:app_id],
              app_secret: @config[:app_secret],
              domain: @config[:domain] || DEFAULT_DOMAIN
            )

            @ws_client.start do |raw_event|
              handle_event(raw_event)
            end
          end

          # Stop the adapter
          # @return [void]
          def stop
            @running = false
            @ws_client&.stop
          end

          # Send plain text message
          # @param chat_id [String] Chat ID
          # @param text [String] Message text
          # @param reply_to [String, nil] Message ID to reply to
          # @return [Hash] Result with :message_id
          def send_text(chat_id, text, reply_to: nil)
            @bot.send_text(chat_id, text, reply_to: reply_to)
          end

          # Update existing message
          # @param chat_id [String] Chat ID (unused for Feishu)
          # @param message_id [String] Message ID to update
          # @param text [String] New text
          # @return [Boolean] Success status
          def update_message(chat_id, message_id, text)
            @bot.update_message(message_id, text)
          end

          # @return [Boolean]
          def supports_message_updates?
            true
          end

          # Validate configuration
          # @param config [Hash] Configuration to validate
          # @return [Array<String>] Error messages
          def validate_config(config)
            errors = []
            errors << "app_id is required" if config[:app_id].nil? || config[:app_id].empty?
            errors << "app_secret is required" if config[:app_secret].nil? || config[:app_secret].empty?
            errors
          end

          private

          # Handle incoming WebSocket event
          # @param raw_event [Hash] Raw event data
          # @return [void]
          def handle_event(raw_event)
            parsed = MessageParser.parse(raw_event)
            return unless parsed

            case parsed[:type]
            when :message
              handle_message_event(parsed)
            when :challenge
              # Challenge is handled by MessageParser
            end
          rescue => e
            warn "Error handling event: #{e.message}"
            warn e.backtrace.join("\n")
          end

          # Handle message event
          # @param event [Hash] Parsed message event
          # @return [void]
          def handle_message_event(event)
            allowed_users = @config[:allowed_users]
            if allowed_users && !allowed_users.empty?
              return unless allowed_users.include?(event[:user_id])
            end

            @on_message&.call(event)
          end
        end

        Adapters.register(:feishu, Adapter)
      end
    end
  end
end
