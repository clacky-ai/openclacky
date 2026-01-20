# frozen_string_literal: true

module Clacky
  module UI2
    # EventBus provides a publish-subscribe mechanism for decoupling business logic from UI
    # Business layer publishes events, UI layer subscribes and renders
    class EventBus
      def initialize
        @subscribers = Hash.new { |h, k| h[k] = [] }
        @mutex = Mutex.new
      end

      # Subscribe to an event
      # @param event_name [Symbol] Event name to subscribe to
      # @param block [Proc] Handler to execute when event is published
      # @return [Integer] Subscription ID for unsubscribing
      def on(event_name, &block)
        @mutex.synchronize do
          subscription_id = generate_subscription_id
          @subscribers[event_name] << { id: subscription_id, handler: block }
          subscription_id
        end
      end

      # Unsubscribe from an event
      # @param event_name [Symbol] Event name
      # @param subscription_id [Integer] ID returned from on()
      def off(event_name, subscription_id)
        @mutex.synchronize do
          @subscribers[event_name].reject! { |sub| sub[:id] == subscription_id }
        end
      end

      # Publish an event with data
      # @param event_name [Symbol] Event name to publish
      # @param data [Hash] Event data to pass to subscribers
      def publish(event_name, data = {})
        handlers = @mutex.synchronize { @subscribers[event_name].dup }
        
        handlers.each do |subscription|
          begin
            subscription[:handler].call(data)
          rescue => e
            # Log error but don't stop other handlers
            warn "EventBus error in handler for #{event_name}: #{e.message}"
          end
        end
      end

      # Clear all subscribers
      def clear
        @mutex.synchronize do
          @subscribers.clear
        end
      end

      # Get subscriber count for an event
      # @param event_name [Symbol] Event name
      # @return [Integer] Number of subscribers
      def subscriber_count(event_name)
        @mutex.synchronize { @subscribers[event_name].size }
      end

      private

      def generate_subscription_id
        @subscription_counter ||= 0
        @subscription_counter += 1
      end
    end
  end
end
