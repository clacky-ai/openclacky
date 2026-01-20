# frozen_string_literal: true

require "spec_helper"
require "clacky/ui2/event_bus"

RSpec.describe Clacky::UI2::EventBus do
  let(:event_bus) { described_class.new }

  describe "#on and #publish" do
    it "executes handler when event is published" do
      received_data = nil
      event_bus.on(:test_event) { |data| received_data = data }

      event_bus.publish(:test_event, { message: "hello" })

      expect(received_data).to eq({ message: "hello" })
    end

    it "supports multiple handlers for the same event" do
      results = []
      event_bus.on(:test_event) { |data| results << data[:value] * 2 }
      event_bus.on(:test_event) { |data| results << data[:value] * 3 }

      event_bus.publish(:test_event, { value: 5 })

      expect(results).to contain_exactly(10, 15)
    end

    it "does not affect other events" do
      result_a = nil
      result_b = nil
      event_bus.on(:event_a) { |data| result_a = data }
      event_bus.on(:event_b) { |data| result_b = data }

      event_bus.publish(:event_a, { value: 1 })

      expect(result_a).to eq({ value: 1 })
      expect(result_b).to be_nil
    end
  end

  describe "#off" do
    it "removes specific subscription" do
      results = []
      id1 = event_bus.on(:test) { |data| results << 1 }
      id2 = event_bus.on(:test) { |data| results << 2 }

      event_bus.off(:test, id1)
      event_bus.publish(:test, {})

      expect(results).to eq([2])
    end
  end

  describe "#clear" do
    it "removes all subscriptions" do
      result = nil
      event_bus.on(:test) { |data| result = data }
      event_bus.clear

      event_bus.publish(:test, { value: 123 })

      expect(result).to be_nil
    end
  end

  describe "#subscriber_count" do
    it "returns number of subscribers for an event" do
      expect(event_bus.subscriber_count(:test)).to eq(0)

      event_bus.on(:test) { }
      event_bus.on(:test) { }

      expect(event_bus.subscriber_count(:test)).to eq(2)
    end
  end

  describe "error handling" do
    it "continues executing other handlers when one fails" do
      results = []
      event_bus.on(:test) { raise "Error!" }
      event_bus.on(:test) { |data| results << data[:value] }

      expect {
        event_bus.publish(:test, { value: 42 })
      }.not_to raise_error

      expect(results).to eq([42])
    end
  end
end
