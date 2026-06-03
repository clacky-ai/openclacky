# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel/adapters/telegram/adapter"
require "clacky/server/channel/adapters/telegram/api_client"

RSpec.describe Clacky::Channel::Adapters::Telegram::Adapter do
  let(:config) do
    {
      bot_token:     "123456:abc",
      base_url:      "https://api.telegram.org",
      parse_mode:    "Markdown",
      allowed_users: []
    }
  end

  let(:adapter) { described_class.new(config) }

  # Pre-populate the cached bot identity so group-mention logic is exercisable
  # without a live network call to getMe.
  before do
    adapter.instance_variable_set(:@bot_id, 9999)
    adapter.instance_variable_set(:@bot_username, "clacky_bot")
  end

  # ──────────────────────────────────────────────────────────────────────────
  describe ".platform_id" do
    it { expect(described_class.platform_id).to eq(:telegram) }
  end

  describe ".platform_config" do
    it "reads env-style keys" do
      cfg = described_class.platform_config(
        "IM_TELEGRAM_BOT_TOKEN"     => "tok",
        "IM_TELEGRAM_BASE_URL"      => "https://proxy.example.com",
        "IM_TELEGRAM_PARSE_MODE"    => "HTML",
        "IM_TELEGRAM_ALLOWED_USERS" => "111, 222"
      )
      expect(cfg).to include(
        bot_token:     "tok",
        base_url:      "https://proxy.example.com",
        parse_mode:    "HTML",
        allowed_users: %w[111 222]
      )
    end

    it "reads raw channels.yml keys (bot_token, base_url, parse_mode)" do
      cfg = described_class.platform_config(
        "bot_token"     => "tok",
        "parse_mode"    => "",
        "allowed_users" => %w[111]
      )
      expect(cfg[:bot_token]).to eq("tok")
      expect(cfg[:parse_mode]).to eq("")        # explicit empty disables parse_mode
      expect(cfg[:allowed_users]).to eq(%w[111])
    end
  end

  describe "#validate_config" do
    it "flags missing bot_token" do
      errors = adapter.validate_config(bot_token: "")
      expect(errors).to include("bot_token is required")
    end

    it "accepts a populated config" do
      expect(adapter.validate_config(bot_token: "tok")).to eq([])
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  describe "#group_mention? (private)" do
    it "returns true when text contains @bot_username as a mention entity" do
      text = "hey @clacky_bot do this"
      offset = text.index("@clacky_bot")
      msg = { "entities" => [{ "type" => "mention", "offset" => offset, "length" => "@clacky_bot".length }] }
      expect(adapter.send(:group_mention?, msg, text)).to eq(true)
    end

    it "returns true when the message replies to the bot" do
      msg = { "reply_to_message" => { "from" => { "id" => 9999 } } }
      expect(adapter.send(:group_mention?, msg, "what about this?")).to eq(true)
    end

    it "returns false when entities contain a non-bot mention" do
      text = "@someone_else hello"
      msg  = { "entities" => [{ "type" => "mention", "offset" => 0, "length" => 13 }] }
      expect(adapter.send(:group_mention?, msg, text)).to eq(false)
    end

    it "fails closed (returns false) when bot identity is unknown" do
      adapter.instance_variable_set(:@bot_id, nil)
      msg = { "entities" => [{ "type" => "mention", "offset" => 0, "length" => 11 }] }
      expect(adapter.send(:group_mention?, msg, "@clacky_bot")).to eq(false)
    end
  end

  describe "#strip_bot_mention (private)" do
    it "removes the @bot_username token" do
      out = adapter.send(:strip_bot_mention, "@clacky_bot please summarize")
      expect(out).to eq("please summarize")
    end

    it "leaves text untouched when bot username is unset" do
      adapter.instance_variable_set(:@bot_username, nil)
      expect(adapter.send(:strip_bot_mention, "@x hi")).to eq("@x hi")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  describe "#process_update" do
    let(:events) { [] }
    before { adapter.instance_variable_set(:@on_message, ->(e) { events << e }) }

    it "yields a standardized event for a private text message" do
      update = {
        "update_id" => 100,
        "message"   => {
          "message_id" => 7,
          "date"       => 1_700_000_000,
          "chat"       => { "id" => 42, "type" => "private" },
          "from"       => { "id" => 1001, "username" => "alice" },
          "text"       => "deploy now"
        }
      }
      adapter.process_update(update)
      expect(events.size).to eq(1)
      expect(events[0]).to include(
        platform:   :telegram,
        chat_id:    "42",
        user_id:    "1001",
        text:       "deploy now",
        chat_type:  :direct,
        message_id: "7"
      )
    end

    it "drops group messages without an @bot mention" do
      update = {
        "update_id" => 101,
        "message"   => {
          "message_id" => 8,
          "date"       => 1_700_000_001,
          "chat"       => { "id" => -100, "type" => "supergroup" },
          "from"       => { "id" => 1001 },
          "text"       => "just chatting"
        }
      }
      adapter.process_update(update)
      expect(events.size).to eq(1)
      expect(events.first[:observe_only]).to be true
    end

    it "accepts group messages when @bot_username is mentioned, and strips the mention" do
      text   = "@clacky_bot summarize this"
      offset = text.index("@clacky_bot")
      update = {
        "update_id" => 102,
        "message"   => {
          "message_id" => 9,
          "date"       => 1_700_000_002,
          "chat"       => { "id" => -200, "type" => "group" },
          "from"       => { "id" => 1002 },
          "text"       => text,
          "entities"   => [{ "type" => "mention", "offset" => offset, "length" => "@clacky_bot".length }]
        }
      }
      adapter.process_update(update)
      expect(events.size).to eq(1)
      expect(events[0][:chat_type]).to eq(:group)
      expect(events[0][:text]).to eq("summarize this")
    end

    it "drops messages from users not on the allowed_users list" do
      adapter.instance_variable_set(:@allowed_users, %w[42])
      update = {
        "update_id" => 103,
        "message"   => {
          "message_id" => 10,
          "date"       => 1_700_000_003,
          "chat"       => { "id" => 99, "type" => "private" },
          "from"       => { "id" => 1003 },
          "text"       => "hi"
        }
      }
      adapter.process_update(update)
      expect(events).to be_empty
    end

    it "drops update payloads without a message key (e.g. edited_message)" do
      expect { adapter.process_update({ "update_id" => 104, "edited_message" => {} }) }.not_to raise_error
      expect(events).to be_empty
    end

    it "uses caption when message has files but no text" do
      update = {
        "update_id" => 105,
        "message"   => {
          "message_id" => 11,
          "date"       => 1_700_000_004,
          "chat"       => { "id" => 50, "type" => "private" },
          "from"       => { "id" => 1004 },
          "caption"    => "look at this",
          "photo"      => []  # empty array → no actual download
        }
      }
      adapter.process_update(update)
      # Empty photo array means no file downloaded; caption alone is enough to deliver
      expect(events.size).to eq(1)
      expect(events[0][:text]).to eq("look at this")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  describe "#split_message (private)" do
    it "returns the input as a single chunk when within limit" do
      expect(adapter.send(:split_message, "short text")).to eq(["short text"])
    end

    it "returns an empty array for empty input" do
      expect(adapter.send(:split_message, "")).to eq([])
    end

    it "splits on paragraph boundary when possible" do
      first  = "a" * 3500
      second = "b" * 1000
      input  = "#{first}\n\n#{second}"
      chunks = adapter.send(:split_message, input)
      expect(chunks.size).to eq(2)
      expect(chunks[0]).to eq(first)
      expect(chunks[1]).to eq(second)
    end

    it "hard-cuts at the limit when no boundary exists" do
      input  = "a" * 5000
      chunks = adapter.send(:split_message, input)
      expect(chunks.size).to be >= 2
      expect(chunks.first.length).to be <= described_class::MAX_MESSAGE_CHARS
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  describe "#detect_image_mime (private)" do
    it "recognises PNG magic bytes" do
      png = "\x89PNG\r\n\x1A\n".b + ("x" * 10)
      expect(adapter.send(:detect_image_mime, png)).to eq("image/png")
    end

    it "recognises GIF magic bytes" do
      gif = "GIF89a".b + ("x" * 10)
      expect(adapter.send(:detect_image_mime, gif)).to eq("image/gif")
    end

    it "recognises WebP magic bytes" do
      webp = "RIFF????WEBP".b
      expect(adapter.send(:detect_image_mime, webp)).to eq("image/webp")
    end

    it "defaults to image/jpeg for unknown / JPEG-looking data" do
      expect(adapter.send(:detect_image_mime, "\xFF\xD8\xFF\xE0".b + ("x" * 10))).to eq("image/jpeg")
      expect(adapter.send(:detect_image_mime, nil)).to eq("image/jpeg")
    end
  end
end
