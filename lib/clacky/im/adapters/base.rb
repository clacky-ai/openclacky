# frozen_string_literal: true

module Clacky
  module IM
    module Adapters
      # Adapter registry: maps platform symbol to adapter class.
      # Each adapter registers itself by calling Adapters.register at load time.
      @registry = {}

      def self.register(platform, klass)
        @registry[platform] = klass
      end

      def self.find(platform)
        @registry[platform]
      end

      # Base adapter interface for IM platforms.
      # All platform adapters must inherit from this class and implement the required methods.
      class Base
        # Platform identifier, e.g. :feishu, :wecom
        # @return [Symbol]
        def self.platform_id
          raise NotImplementedError, "#{self} must implement .platform_id"
        end

        # Map raw env data hash to platform config hash.
        # @param data [Hash] Raw env data (string keys)
        # @return [Hash] Platform config (symbol keys)
        def self.platform_config(data)
          raise NotImplementedError, "#{self} must implement .platform_config"
        end

        # Write platform config values back into raw env data hash.
        # @param data [Hash] Raw env data to mutate (string keys)
        # @param config [Hash] Platform config (symbol keys)
        # @return [void]
        def self.set_env_data(data, config)
          raise NotImplementedError, "#{self} must implement .set_env_data"
        end

        # List of env variable names this platform uses (for config file serialization).
        # @return [Array<String>]
        def self.env_keys
          raise NotImplementedError, "#{self} must implement .env_keys"
        end

        # @return [Symbol] Platform identifier
        def platform_id
          self.class.platform_id
        end

        # Start the adapter and begin listening for messages.
        # This method should block until stopped.
        # @yield [event] Yields an inbound message hash for each received message
        # @return [void]
        def start(&on_message)
          raise NotImplementedError, "#{self.class} must implement #start"
        end

        # Stop the adapter and clean up resources.
        # @return [void]
        def stop
          raise NotImplementedError, "#{self.class} must implement #stop"
        end

        # Send a plain text message to a chat.
        # @param chat_id [String] Target chat identifier
        # @param text [String] Message text
        # @param reply_to [String, nil] Optional message ID to reply to
        # @return [Hash] Result with :message_id if successful
        def send_text(chat_id, text, reply_to: nil)
          raise NotImplementedError, "#{self.class} must implement #send_text"
        end

        # Update an existing message (for progress display).
        # @param chat_id [String] Target chat identifier
        # @param message_id [String] Message ID to update
        # @param text [String] New message text
        # @return [Boolean] true if successful
        def update_message(chat_id, message_id, text)
          false
        end

        # Check if the adapter supports message updates (progress display).
        # @return [Boolean]
        def supports_message_updates?
          false
        end

        # Validate adapter configuration.
        # @param config [Hash] Configuration hash
        # @return [Array<String>] Array of error messages (empty if valid)
        def validate_config(config)
          []
        end
      end
    end
  end
end
