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
      or-gemini-3-1-pro or-gemini-3-8-flash or-gemini-3-6-flash or-gemini-3-7-flash or-gemini-3-5-flash
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
      expect(result[:prices]["or-gemini-3-5-flash"][:ratio]).to be_within(0.001).of((0.5 + 3.0) / base_total)
    end

    it "returns input/output prices alongside the ratio" do
      result = described_class.build("or-gemini-3-5-flash")

      expect(result[:prices]["or-gemini-3-5-flash"]).to eq(in: 0.5, out: 3.0, ratio: (0.5 + 3.0) / 12.0)
    end

    it "applies provider prefix and alias normalization" do
      result = described_class.build("or-gemini-3-5-flash,claude-sonnet-4-6")

      expect(result[:prices]["or-gemini-3-5-flash"]).to eq(in: 0.5, out: 3.0, ratio: (0.5 + 3.0) / 12.0)
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
          in: 1.6, out: 8.0, ratio: (1.6 + 8.0) / base_total, discount: { rate: 0.8 }
        )
        expect(result[:prices]["abs-claude-fable-5"]).to eq(
          in: 8.0, out: 40.0, ratio: (8.0 + 40.0) / base_total, discount: { rate: 0.8 }
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

      it "applies the TokHub promotion to the oc-prefixed aliases" do
        result = described_class.build("oc-glm-5.3,oc-kimi-k3,oc-minimax-m2.7")

        expect(result[:prices]["oc-glm-5.3"]).to eq(
          in: 1.0849, out: 3.8, ratio: (1.0849 + 3.8) / base_total,
          discount: { rate: 0.95 }
        )
        expect(result[:prices]["oc-kimi-k3"]).to eq(
          in: 2.85, out: 14.25,
          ratio: (2.85 + 14.25) / base_total, discount: { rate: 0.95 }
        )
        expect(result[:prices]["oc-minimax-m2.7"]).to eq(
          in: 0.285, out: 1.14,
          ratio: (0.285 + 1.14) / base_total, discount: { rate: 0.95 }
        )
      end

      it "omits the discount flag for models outside the promotion" do
        result = described_class.build("or-gemini-3-5-flash")

        expect(result[:prices]["or-gemini-3-5-flash"]).not_to have_key(:discount)
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
