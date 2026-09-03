# frozen_string_literal: true

require "spec_helper"
require "clacky/billing/platform_billing"

RSpec.describe Clacky::Billing::PlatformBilling do
  let(:client) { double("platform client") }

  before do
    allow(Clacky::PlatformHttpClient).to receive(:new).and_return(client)
  end

  def stub_key(key, payload)
    allow(client).to receive(:get)
      .with(anything, hash_including(headers: hash_including("Authorization" => "Bearer #{key}")))
      .and_return({ success: true, data: payload })
  end

  def stub_failed_key(key)
    allow(client).to receive(:get)
      .with(anything, hash_including(headers: hash_including("Authorization" => "Bearer #{key}")))
      .and_return({ success: false, error: "Invalid API key", data: {} })
  end

  def summary_payload(cost:, prompt:, completion:, cache_read:, model_cost:, requests:, day_cost:)
    {
      "period" => "month",
      "from" => "2026-09-01T00:00:00+08:00",
      "to" => "2026-09-03T17:00:00+08:00",
      "total_cost" => cost,
      "total_tokens" => prompt + completion,
      "prompt_tokens" => prompt,
      "completion_tokens" => completion,
      "cache_read_tokens" => cache_read,
      "cache_write_tokens" => 0,
      "by_model" => {
        "deepseek-v4-pro" => {
          "cost" => model_cost,
          "prompt_tokens" => prompt,
          "completion_tokens" => completion,
          "requests" => requests
        }
      },
      "by_day" => { "2026-09-02" => day_cost },
      "record_count" => requests,
      "source" => "platform"
    }
  end

  def daily_payload(date:, cost:, tokens:, requests:)
    {
      "days" => [
        {
          "date" => date,
          "cost" => cost,
          "tokens" => tokens,
          "prompt_tokens" => tokens - 10,
          "completion_tokens" => 10,
          "cache_read_tokens" => 0,
          "cache_write_tokens" => 0,
          "requests" => requests
        }
      ]
    }
  end

  describe ".fetch_summary_merged" do
    it "merges summaries from all working keys" do
      stub_key("clacky-a", summary_payload(
                              cost: 1.5, prompt: 60, completion: 40, cache_read: 10,
                              model_cost: 1.5, requests: 3, day_cost: 1.5
                            ))
      stub_key("clacky-b", summary_payload(
                              cost: 2.0, prompt: 80, completion: 20, cache_read: 5,
                              model_cost: 2.0, requests: 2, day_cost: 2.0
                            ))

      merged = described_class.fetch_summary_merged(["clacky-a", "clacky-b"], period: "month")

      expect(merged[:total_cost]).to eq(3.5)
      expect(merged[:record_count]).to eq(5)
      expect(merged[:by_model]["deepseek-v4-pro"]).to eq(
        cost: 3.5,
        prompt_tokens: 140,
        completion_tokens: 60,
        requests: 5
      )
      expect(merged[:by_day]["2026-09-02"]).to eq(3.5)
      expect(merged[:period]).to eq("month")
      expect(merged[:source]).to eq("platform")
    end

    it "folds cache_read into prompt_tokens per key before merging" do
      stub_key("clacky-a", summary_payload(
                              cost: 1.0, prompt: 60, completion: 40, cache_read: 10,
                              model_cost: 1.0, requests: 1, day_cost: 1.0
                            ))
      stub_key("clacky-b", summary_payload(
                              cost: 1.0, prompt: 80, completion: 20, cache_read: 5,
                              model_cost: 1.0, requests: 1, day_cost: 1.0
                            ))

      merged = described_class.fetch_summary_merged(["clacky-a", "clacky-b"], period: "month")

      # key a: prompt 60+10 cache_read = 70, total 100+10 = 110
      # key b: prompt 80+5 = 85, total 100+5 = 105 → 215
      expect(merged[:prompt_tokens]).to eq(155)
      expect(merged[:total_tokens]).to eq(215)
    end

    it "skips failing keys and still returns the working key's data" do
      stub_failed_key("clacky-bad")
      stub_key("clacky-good", summary_payload(
                                  cost: 2.0, prompt: 50, completion: 50, cache_read: 0,
                                  model_cost: 2.0, requests: 2, day_cost: 2.0
                                ))

      merged = described_class.fetch_summary_merged(["clacky-bad", "clacky-good"], period: "month")

      expect(merged[:total_cost]).to eq(2.0)
      expect(merged[:record_count]).to eq(2)
    end

    it "returns nil when every key fails" do
      stub_failed_key("clacky-a")
      stub_failed_key("clacky-b")

      expect(described_class.fetch_summary_merged(["clacky-a", "clacky-b"], period: "month")).to be_nil
    end

    it "returns nil for an empty key list" do
      expect(described_class.fetch_summary_merged([], period: "month")).to be_nil
    end

    it "queries a duplicated key only once" do
      stub_key("clacky-a", summary_payload(
                              cost: 1.0, prompt: 10, completion: 5, cache_read: 0,
                              model_cost: 1.0, requests: 1, day_cost: 1.0
                            ))

      merged = described_class.fetch_summary_merged(["clacky-a", "clacky-a"], period: "month")

      expect(client).to have_received(:get).once
      expect(merged[:total_cost]).to eq(1.0)
    end

    it "passes the model filter through" do
      stub_key("clacky-a", summary_payload(
                              cost: 1.0, prompt: 10, completion: 5, cache_read: 0,
                              model_cost: 1.0, requests: 1, day_cost: 1.0
                            ))

      described_class.fetch_summary_merged(["clacky-a"], period: "month", model: "deepseek-v4-pro")

      expect(client).to have_received(:get)
        .with("/api/v1/usage/summary?period=month&model=deepseek-v4-pro", anything)
    end
  end

  describe ".fetch_daily_merged" do
    it "merges daily entries from all working keys by date" do
      stub_key("clacky-a", daily_payload(date: "2026-09-02", cost: 0.5, tokens: 100, requests: 2))
      stub_key("clacky-b", daily_payload(date: "2026-09-02", cost: 0.3, tokens: 40, requests: 1))

      merged = described_class.fetch_daily_merged(["clacky-a", "clacky-b"], days: 30)

      expect(merged[:days]).to eq([
                                    {
                                      date: "2026-09-02",
                                      cost: 0.8,
                                      tokens: 140,
                                      prompt_tokens: 120,
                                      completion_tokens: 20,
                                      cache_read_tokens: 0,
                                      cache_write_tokens: 0,
                                      requests: 3
                                    }
                                  ])
    end

    it "keeps entries from different keys on distinct dates sorted" do
      stub_key("clacky-a", daily_payload(date: "2026-09-03", cost: 1.0, tokens: 10, requests: 1))
      stub_key("clacky-b", daily_payload(date: "2026-09-01", cost: 2.0, tokens: 20, requests: 1))

      merged = described_class.fetch_daily_merged(["clacky-a", "clacky-b"], days: 30)

      expect(merged[:days].map { |d| d[:date] }).to eq(["2026-09-01", "2026-09-03"])
    end

    it "skips failing keys and still returns the working key's data" do
      stub_failed_key("clacky-bad")
      stub_key("clacky-good", daily_payload(date: "2026-09-02", cost: 0.7, tokens: 50, requests: 1))

      merged = described_class.fetch_daily_merged(["clacky-bad", "clacky-good"], days: 30)

      expect(merged[:days].length).to eq(1)
      expect(merged[:days].first[:cost]).to eq(0.7)
    end

    it "returns nil when every key fails" do
      stub_failed_key("clacky-a")

      expect(described_class.fetch_daily_merged(["clacky-a"], days: 30)).to be_nil
    end

    it "returns nil for an empty key list" do
      expect(described_class.fetch_daily_merged([], days: 30)).to be_nil
    end
  end
end
