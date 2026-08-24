# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ThreadRegistry do
  describe ".spawn" do
    it "swallows AgentInterrupted so the thread exits cleanly and join does not re-raise" do
      thread = described_class.spawn(name: "spec-interrupt") do
        raise Clacky::AgentInterrupted, "shutdown requested"
      end

      expect { thread.join }.not_to raise_error
      expect(thread).not_to be_alive
    end

    it "unregisters the thread after an AgentInterrupted exit" do
      thread = described_class.spawn(name: "spec-interrupt-cleanup") do
        raise Clacky::AgentInterrupted, "shutdown requested"
      end
      thread.join

      expect(Clacky::ThreadRegistry::ENTRIES).not_to have_key(thread)
    end

    it "still lets real exceptions terminate the thread (join re-raises)" do
      thread = described_class.spawn(name: "spec-real-error") do
        raise "boom"
      end
      thread.report_on_exception = false # keep test output clean

      expect { thread.join }.to raise_error(RuntimeError, "boom")
      expect(thread).not_to be_alive
    end
  end
end
