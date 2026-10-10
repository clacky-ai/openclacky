# frozen_string_literal: true

require "clacky/server/channel/adapters/qq/adapter"

RSpec.describe Clacky::Channel::Adapters::Qq::Adapter do
  let(:config) do
    { app_id: "102030", app_secret: "super-secret", intents: described_class::DEFAULT_INTENTS }
  end
  let(:adapter) do
    described_class.new(config).tap do |a|
      a.instance_variable_set(:@api, api)
    end
  end
  let(:api) { instance_double(Clacky::Channel::Adapters::Qq::ApiClient) }

  describe ".platform_id" do
    it "is :qq" do
      expect(described_class.platform_id).to eq(:qq)
    end
  end

  describe ".platform_config" do
    it "maps the standard keys and defaults intents" do
      cfg = described_class.platform_config(
        "app_id" => "abc", "app_secret" => "shh", "sandbox" => false
      )
      expect(cfg[:app_id]).to eq("abc")
      expect(cfg[:app_secret]).to eq("shh")
      expect(cfg[:intents]).to eq(described_class::DEFAULT_INTENTS)
      expect(cfg[:allowed_users]).to eq([])
    end

    it "uses the sandbox base url when sandbox is enabled without explicit base_url" do
      cfg = described_class.platform_config("app_id" => "a", "app_secret" => "b", "sandbox" => true)
      expect(cfg[:base_url]).to eq(described_class::SANDBOX_BASE_URL)
    end

    it "parses a comma-separated allowed_users string" do
      cfg = described_class.platform_config(
        "app_id" => "a", "app_secret" => "b", "allowed_users" => "u1, u2 ,u3"
      )
      expect(cfg[:allowed_users]).to eq(%w[u1 u2 u3])
    end

    it "parses numeric intents" do
      cfg = described_class.platform_config(
        "app_id" => "a", "app_secret" => "b", "intents" => "1073741825"
      )
      expect(cfg[:intents]).to eq(1_073_741_825)
    end
  end

  describe "#supports_files?" do
    it "is true" do
      expect(adapter.supports_files?).to be(true)
    end
  end

  describe "#supports_message_updates?" do
    it "is false" do
      expect(adapter.supports_message_updates?).to be(false)
    end
  end

  describe "#validate_config" do
    it "returns no errors for a complete config" do
      expect(adapter.validate_config(config)).to eq([])
    end

    it "reports missing app_id and app_secret" do
      errors = adapter.validate_config(app_id: "", app_secret: nil)
      expect(errors).to include("app_id is required", "app_secret is required")
    end
  end

  describe "#send_text" do
    it "posts a c2c text message and returns the message id" do
      expect(api).to receive(:send_c2c_message)
        .with("openid-1", hash_including(content: "hi", msg_type: 0))
        .and_return("id" => "msg-9")
      result = adapter.send_text("c2c:openid-1", "hi")
      expect(result).to eq(message_id: "msg-9")
    end

    it "posts a group text message with reply_to as msg_id" do
      expect(api).to receive(:send_group_message)
        .with("group-openid", hash_including(content: "yo", msg_id: "inbound-1"))
        .and_return("message_id" => "msg-10")
      result = adapter.send_text("group:group-openid", "yo", reply_to: "inbound-1")
      expect(result).to eq(message_id: "msg-10")
    end

    it "splits text longer than MAX_MESSAGE_CHARS into multiple posts" do
      long = "a" * (described_class::MAX_MESSAGE_CHARS + 100)
      call_count = 0
      allow(api).to receive(:send_c2c_message) do |_openid, body|
        call_count += 1
        { "id" => "chunk-#{call_count}", "echo" => body[:content].length }
      end
      result = adapter.send_text("c2c:u1", long)
      expect(call_count).to eq(2)
      expect(result).to eq(message_id: "chunk-2")
    end

    it "returns a nil message id for guild scopes" do
      expect(adapter.send_text("guild:channel-1", "hi")).to eq(message_id: nil)
    end

    it "swallows API errors and returns a nil message id" do
      allow(api).to receive(:send_c2c_message)
        .and_raise(Clacky::Channel::Adapters::Qq::ApiClient::ApiError, "boom")
      expect(adapter.send_text("c2c:u1", "hi")).to eq(message_id: nil)
    end
  end

  describe "#process_event" do
    it "maps C2C_MESSAGE_CREATE to a c2c message event" do
      received = nil
      capture(adapter) { |event| received = event }
      adapter.process_event(
        "C2C_MESSAGE_CREATE",
        "id" => "m1", "content" => "hello bot",
        "author" => { "user_openid" => "user-1" }, "timestamp" => "2026-10-09T01:02:03+08:00"
      )
      expect(received).not_to be_nil
      expect(received[:platform]).to eq(:qq)
      expect(received[:chat_id]).to eq("c2c:user-1")
      expect(received[:user_id]).to eq("user-1")
      expect(received[:text]).to eq("hello bot")
      expect(received[:chat_type]).to eq(:direct)
      expect(received[:message_id]).to eq("m1")
    end

    it "maps GROUP_AT_MESSAGE_CREATE to a group message event" do
      received = nil
      capture(adapter) { |event| received = event }
      adapter.process_event(
        "GROUP_AT_MESSAGE_CREATE",
        "id" => "m2", "content" => "@bot help", "group_openid" => "grp-1",
        "author" => { "member_openid" => "mem-1" }
      )
      expect(received[:chat_id]).to eq("group:grp-1")
      expect(received[:user_id]).to eq("mem-1")
      expect(received[:chat_type]).to eq(:group)
    end

    it "maps guild AT_MESSAGE_CREATE with a guild scope chat id" do
      received = nil
      capture(adapter) { |event| received = event }
      adapter.process_event(
        "AT_MESSAGE_CREATE",
        "id" => "m3", "content" => "ping", "channel_id" => "chan-7",
        "author" => { "id" => "guild-user" }
      )
      expect(received[:chat_id]).to eq("guild:chan-7")
    end

    it "ignores the same msg_id on redelivery" do
      count = 0
      capture(adapter) { |_event| count += 1 }
      payload = {
        "id" => "dup-1", "content" => "repeat",
        "author" => { "user_openid" => "user-1" }
      }
      adapter.process_event("C2C_MESSAGE_CREATE", payload)
      adapter.process_event("C2C_MESSAGE_CREATE", payload)
      expect(count).to eq(1)
    end

    it "ignores empty messages without attachments" do
      called = false
      capture(adapter) { |_event| called = true }
      adapter.process_event(
        "C2C_MESSAGE_CREATE",
        "id" => "m4", "content" => "", "author" => { "user_openid" => "user-1" }
      )
      expect(called).to be(false)
    end

    it "uses the voice ASR text when content is empty" do
      received = nil
      capture(adapter) { |event| received = event }
      adapter.process_event(
        "C2C_MESSAGE_CREATE",
        "id" => "m5", "content" => "", "author" => { "user_openid" => "user-1" },
        "attachments" => [{ "content_type" => "voice/silk", "asr_refer_text" => "你好" }]
      )
      expect(received[:text]).to eq("你好")
    end

    it "respects the allowed_users whitelist" do
      restricted = described_class.new(config.merge(allowed_users: %w[allowed-one]))
      received = nil
      capture(restricted) { |event| received = event }
      restricted.process_event(
        "C2C_MESSAGE_CREATE",
        "id" => "m6", "content" => "hi", "author" => { "user_openid" => "other-user" }
      )
      expect(received).to be_nil
    end

    it "ignores non-hash payloads" do
      expect { adapter.process_event("C2C_MESSAGE_CREATE", nil) }.not_to raise_error
    end
  end

  def capture(adapter, &block)
    adapter.instance_variable_set(:@on_message, block)
  end

  describe "load order" do
    it "defines QrBinder once the channel layer is loaded" do
      lib = File.expand_path("../../../../lib", __dir__)
      script = "require \"clacky\"; require \"clacky/server/channel\"; " \
               "print Clacky::Channel::Adapters::Qq::QrBinder"
      out = IO.popen([RbConfig.ruby, "-I", lib, "-e", script], err: [:child, :out], &:read)
      expect(out).to eq("Clacky::Channel::Adapters::Qq::QrBinder"), out
    end
  end

  describe "#remember_msg_id / #last_msg_id_for" do
    it "stores and retrieves the last inbound msg id" do
      adapter.remember_msg_id("c2c:u1", "in-1")
      expect(adapter.last_msg_id_for("c2c:u1")).to eq("in-1")
    end
  end

  describe "#split_message" do
    it "returns an empty array for nil or empty text" do
      expect(adapter.send(:split_message, nil)).to eq([])
      expect(adapter.send(:split_message, "")).to eq([])
    end

    it "keeps short text in one chunk" do
      expect(adapter.send(:split_message, "short")).to eq(["short"])
    end
  end
end
