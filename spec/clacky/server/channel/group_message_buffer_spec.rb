# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel/group_message_buffer"

RSpec.describe Clacky::Channel::GroupMessageBuffer do
  subject(:buffer) { described_class.new }

  describe "#push / #take" do
    it "returns entries in insertion order" do
      buffer.push("chat1", user_id: "alice", text: "hello")
      buffer.push("chat1", user_id: "bob",   text: "world")

      entries = buffer.take("chat1")
      expect(entries.map(&:user_id)).to eq(%w[alice bob])
      expect(entries.map(&:text)).to   eq(%w[hello world])
    end

    it "isolates entries by chat_id" do
      buffer.push("chat1", user_id: "alice", text: "in chat1")
      buffer.push("chat2", user_id: "bob",   text: "in chat2")

      expect(buffer.take("chat1").map(&:text)).to eq(["in chat1"])
      expect(buffer.take("chat2").map(&:text)).to eq(["in chat2"])
    end

    it "clears the buffer after take" do
      buffer.push("chat1", user_id: "alice", text: "hi")
      buffer.take("chat1")
      expect(buffer.take("chat1")).to be_empty
    end

    it "returns an empty array for an unknown chat_id" do
      expect(buffer.take("nonexistent")).to eq([])
    end

    it "drops blank messages silently" do
      buffer.push("chat1", user_id: "alice", text: "  ")
      expect(buffer.take("chat1")).to be_empty
    end
  end

  describe "MAX_MESSAGES cap" do
    it "keeps only the most recent MAX_MESSAGES entries" do
      (Clacky::Channel::GroupMessageBuffer::MAX_MESSAGES + 5).times do |i|
        buffer.push("chat1", user_id: "u", text: "msg#{i}")
      end

      entries = buffer.take("chat1")
      expect(entries.size).to eq(Clacky::Channel::GroupMessageBuffer::MAX_MESSAGES)
      expect(entries.last.text).to eq("msg#{Clacky::Channel::GroupMessageBuffer::MAX_MESSAGES + 4}")
    end
  end

  describe "thread safety" do
    it "does not raise or corrupt state under concurrent writes and reads" do
      threads = 10.times.map do |i|
        Thread.new { buffer.push("chat1", user_id: "u#{i}", text: "msg#{i}") }
      end
      threads.each(&:join)

      entries = buffer.take("chat1")
      expect(entries.size).to be <= Clacky::Channel::GroupMessageBuffer::MAX_MESSAGES
      expect(entries).to all(be_a(Clacky::Channel::GroupMessageBuffer::Entry))
    end
  end
end
