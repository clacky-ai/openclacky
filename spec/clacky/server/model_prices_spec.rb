# frozen_string_literal: true

require "spec_helper"
require "clacky/utils/model_pricing"
require "clacky/server/model_prices"

RSpec.describe Clacky::Server::ModelPrices do
  let(:panel_models) do
    %w[
      abs-claude-fable-5-1 abs-claude-fable-5 abs-claude-opus-5 abs-claude-opus-4-8 abs-claude-opus-4-7
      abs-claude-opus-4-6 abs-claude-sonnet-5-5 abs-claude-sonnet-5 abs-claude-sonnet-4-6 abs-claude-sonnet-4-5
      abs-claude-haiku-4-5 dsk-deepseek-v4-pro dsk-deepseek-v4-flash
      or-gemini-4-argon or-gemini-3-1-pro or-gemini-3-8-flash or-gemini-3-6-flash or-gemini-3-7-flash or-gemini-3-5-flash
    ]
  end

  describe ".build" do
    it "returns the baseline model and its prices" do
      result = described_class.build("abs-claude-sonnet-5")

      expect(result[:baseline]).to eq(model: "claude-sonnet-5", in: 2.0, out: 10.0)
    end

    it "resolves every model shown in the submodel switcher panel" do
      result = described_class.build(panel_models.join(","))

      expect(result[:prices].keys).to eq(panel_models)
    end

    it "calculates ratios against the baseline default rates" do
      result = described_class.build("claude-sonnet-4-6,or-gemini-3-5-flash")
      base_total = 2.0 + 10.0

      expect(result[:prices]["claude-sonnet-4-6"][:ratio]).to be_within(0.001).of((3.0 + 15.0) / base_total)
      expect(result[:prices]["or-gemini-3-5-flash"][:ratio]).to be_within(0.001).of((0.4 + 2.4) / base_total)
    end

    it "returns input/output prices alongside the ratio" do
      result = described_class.build("or-gemini-3-5-flash")

      expect(result[:prices]["or-gemini-3-5-flash"]).to eq(
        in: 0.4, out: 2.4, ratio: (0.4 + 2.4) / 12.0, discount: { rate: 0.8, reason: "promo" }
      )
    end

    it "applies provider prefix and alias normalization" do
      result = described_class.build("or-gemini-3-5-flash,claude-sonnet-4-6")

      expect(result[:prices]["or-gemini-3-5-flash"]).to eq(
        in: 0.4, out: 2.4, ratio: (0.4 + 2.4) / 12.0, discount: { rate: 0.8, reason: "promo" }
      )
      expect(result[:prices]["claude-sonnet-4-6"][:ratio]).to eq((3.0 + 15.0) / 12.0)
    end

    it "excludes unknown models instead of guessing" do
      result = described_class.build("abs-claude-sonnet-5,totally-unknown-model")

      expect(result[:prices]).to have_key("abs-claude-sonnet-5")
      expect(result[:prices]).not_to have_key("totally-unknown-model")
    end

    it "handles nil, empty and whitespace-only queries" do
      expect(described_class.build(nil)[:prices]).to eq({})
      expect(described_class.build("")[:prices]).to eq({})
      expect(described_class.build(" , ,")[:prices]).to eq({})
    end

    it "strips whitespace around names" do
      result = described_class.build(" abs-claude-sonnet-5 ")

      expect(result[:prices]).to have_key("abs-claude-sonnet-5")
    end

    context "with an active series promotion" do
      let(:base_total) { 2.0 + 10.0 }

      it "discounts the platform-served Claude aliases and reports the rate" do
        result = described_class.build("abs-claude-sonnet-5,abs-claude-fable-5")

        expect(result[:prices]["abs-claude-sonnet-5"]).to eq(
          in: 0.9, out: 4.5, ratio: (0.9 + 4.5) / base_total, discount: { rate: 0.45, reason: "channel" }
        )
        expect(result[:prices]["abs-claude-fable-5"]).to eq(
          in: 4.5, out: 22.5, ratio: (4.5 + 22.5) / base_total, discount: { rate: 0.45, reason: "channel" }
        )
      end

      it "prices Haiku 5.5 off its sub-100K card" do
        result = described_class.build("abs-claude-haiku-5-5")

        expect(result[:prices]["abs-claude-haiku-5-5"]).to eq(
          in: 0.045, out: 0.225, ratio: (0.045 + 0.225) / base_total, discount: { rate: 0.45, reason: "channel" }
        )
      end

      it "keeps the baseline at list price so the ratio stays comparable" do
        result = described_class.build("abs-claude-sonnet-5")

        expect(result[:baseline]).to eq(model: "claude-sonnet-5", in: 2.0, out: 10.0)
      end

      it "leaves BYOK ids sharing the same pricing entry at list price" do
        result = described_class.build("claude-sonnet-5,claude-sonnet-5-5,claude-opus-5")

        expect(result[:prices]["claude-sonnet-5"]).to eq(in: 2.0, out: 10.0, ratio: 1.0)
        expect(result[:prices]["claude-sonnet-5-5"]).to eq(in: 2.0, out: 10.0, ratio: 1.0)
        expect(result[:prices]["claude-opus-5"]).to eq(in: 5.0, out: 25.0, ratio: (5.0 + 25.0) / base_total)
      end

      it "applies the ciyuan promotion to the oc-prefixed aliases" do
        result = described_class.build("oc-glm-5.3,oc-kimi-k3,oc-grok-4.7")

        expect(result[:prices]["oc-glm-5.3"]).to eq(
          in: 1.0849, out: 3.8, ratio: (1.0849 + 3.8) / base_total,
          discount: { rate: 0.95, reason: "channel" }
        )
        expect(result[:prices]["oc-kimi-k3"]).to eq(
          in: 2.7, out: 13.5,
          ratio: (2.7 + 13.5) / base_total, discount: { rate: 0.9, reason: "channel" }
        )
        expect(result[:prices]["oc-grok-4.7"]).to eq(
          in: 0.6, out: 1.8,
          ratio: (0.6 + 1.8) / base_total, discount: { rate: 0.3, reason: "channel" }
        )
      end

      it "applies the gpt promotion to oc-gpt-6.1-sol" do
        result = described_class.build("oc-gpt-6.1-sol")

        expect(result[:prices]["oc-gpt-6.1-sol"]).to eq(
          in: 0.6, out: 3.0,
          ratio: (0.6 + 3.0) / base_total, discount: { rate: 0.3, reason: "channel" }
        )
      end

      it "applies the gpt promotion to oc-gpt-6-astra" do
        result = described_class.build("oc-gpt-6-astra")

        expect(result[:prices]["oc-gpt-6-astra"]).to eq(
          in: 3.0, out: 15.0,
          ratio: (3.0 + 15.0) / base_total, discount: { rate: 0.3, reason: "channel" }
        )
      end

      it "applies the gpt promotion to oc-gpt-6-sol" do
        result = described_class.build("oc-gpt-6-sol")

        expect(result[:prices]["oc-gpt-6-sol"]).to eq(
          in: 0.6, out: 3.0,
          ratio: (0.6 + 3.0) / base_total, discount: { rate: 0.3, reason: "channel" }
        )
      end

      it "applies the gpt promotion to oc-gpt-6-luna" do
        result = described_class.build("oc-gpt-6-luna")

        expect(result[:prices]["oc-gpt-6-luna"]).to eq(
          in: 0.03, out: 0.15,
          ratio: (0.03 + 0.15) / base_total, discount: { rate: 0.3, reason: "channel" }
        )
      end

      it "reports the Vertex launch promo on the or-prefixed aliases" do
        result = described_class.build("or-gemini-4-argon,or-gemini-3-1-pro")

        expect(result[:prices]["or-gemini-4-argon"]).to eq(
          in: 1.6, out: 8.0,
          ratio: (1.6 + 8.0) / base_total, discount: { rate: 0.8, reason: "promo" }
        )
        expect(result[:prices]["or-gemini-3-1-pro"]).to eq(
          in: 1.6, out: 9.6,
          ratio: (1.6 + 9.6) / base_total, discount: { rate: 0.8, reason: "promo" }
        )
      end

      it "applies the Bedrock markup instead of a discount" do
        result = described_class.build("abs-gpt-6.1-sol")

        # $2 in / $10 out at list, billed at 1.2x by the Bedrock GPT lane.
        expect(result[:prices]["abs-gpt-6.1-sol"]).to eq(
          in: 2.4, out: 12.0, ratio: (2.4 + 12.0) / base_total
        )
        expect(result[:prices]["abs-gpt-6.1-sol"]).not_to have_key(:discount)
      end

      it "leaves the BYOK gpt id at list price" do
        result = described_class.build("gpt-6.1-sol")

        expect(result[:prices]["gpt-6.1-sol"]).to eq(in: 2.0, out: 10.0, ratio: 1.0)
      end
    end

    context "with DeepSeek time-of-day tiers" do
      let(:peak_time)     { Time.utc(2026, 8, 17, 2, 0, 0) }  # 02:00 UTC -> peak
      let(:off_peak_time) { Time.utc(2026, 8, 17, 5, 0, 0) }  # 05:00 UTC -> off-peak
      let(:base_total)    { 12.0 }

      it "uses peak rates during peak hours" do
        result = described_class.build("dsk-deepseek-v4-flash", now: peak_time)

        expect(result[:prices]["dsk-deepseek-v4-flash"]).to eq(in: 0.30, out: 1.20, ratio: (0.30 + 1.20) / base_total)
      end

      it "uses off-peak rates (half of peak) outside peak hours" do
        result = described_class.build("dsk-deepseek-v4-flash", now: off_peak_time)

        expect(result[:prices]["dsk-deepseek-v4-flash"]).to eq(in: 0.15, out: 0.60, ratio: (0.15 + 0.60) / base_total)
      end
    end
  end
end
