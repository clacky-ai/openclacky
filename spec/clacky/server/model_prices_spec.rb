# frozen_string_literal: true

require "spec_helper"
require "clacky/utils/model_pricing"
require "clacky/server/model_prices"

RSpec.describe Clacky::Server::ModelPrices do
  let(:panel_models) do
    %w[
      abs-claude-fable-5-1 abs-claude-fable-5 abs-claude-opus-5 abs-claude-opus-4-8 abs-claude-opus-4-7
      abs-claude-opus-4-6 abs-claude-sonnet-5 abs-claude-sonnet-4-6 abs-claude-sonnet-4-5
      abs-claude-haiku-4-5 dsk-deepseek-v4-pro dsk-deepseek-v4-flash
      or-gemini-3-1-pro or-gemini-3-8-flash or-gemini-3-6-flash or-gemini-3-7-flash or-gemini-3-5-flash
    ]
  end

  describe ".build" do
    it "returns the baseline model and its prices" do
      result = described_class.build("abs-claude-sonnet-5")

      expect(result[:baseline]).to eq(model: "claude-sonnet-5", in: 3.0, out: 15.0)
    end

    it "resolves every model shown in the submodel switcher panel" do
      result = described_class.build(panel_models.join(","))

      expect(result[:prices].keys).to eq(panel_models)
    end

    it "calculates ratios against the baseline default rates" do
      result = described_class.build("abs-claude-fable-5,abs-claude-opus-4-6,abs-claude-haiku-4-5")
      base_total = 3.0 + 15.0

      expect(result[:prices]["abs-claude-fable-5"][:ratio]).to be_within(0.001).of((10.0 + 50.0) / base_total)
      expect(result[:prices]["abs-claude-opus-4-6"][:ratio]).to be_within(0.001).of((5.0 + 25.0) / base_total)
      expect(result[:prices]["abs-claude-haiku-4-5"][:ratio]).to be_within(0.001).of((1.0 + 5.0) / base_total)
    end

    it "returns input/output prices alongside the ratio" do
      result = described_class.build("abs-claude-sonnet-5")

      expect(result[:prices]["abs-claude-sonnet-5"]).to eq(in: 3.0, out: 15.0, ratio: 1.0)
    end

    it "applies provider prefix and alias normalization" do
      result = described_class.build("or-gemini-3-5-flash,claude-sonnet-4-6")

      expect(result[:prices]["or-gemini-3-5-flash"]).to eq(in: 0.5, out: 3.0, ratio: (0.5 + 3.0) / 18.0)
      expect(result[:prices]["claude-sonnet-4-6"][:ratio]).to eq(1.0)
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

    context "with DeepSeek time-of-day tiers" do
      let(:peak_time)     { Time.utc(2026, 8, 17, 2, 0, 0) }  # 02:00 UTC -> peak
      let(:off_peak_time) { Time.utc(2026, 8, 17, 5, 0, 0) }  # 05:00 UTC -> off-peak
      let(:base_total)    { 18.0 }

      it "uses peak rates during peak hours" do
        result = described_class.build("dsk-deepseek-v4-flash", now: peak_time)

        expect(result[:prices]["dsk-deepseek-v4-flash"]).to eq(in: 0.44, out: 1.32, ratio: (0.44 + 1.32) / base_total)
      end

      it "uses off-peak rates (half of peak) outside peak hours" do
        result = described_class.build("dsk-deepseek-v4-flash", now: off_peak_time)

        expect(result[:prices]["dsk-deepseek-v4-flash"]).to eq(in: 0.22, out: 0.66, ratio: (0.22 + 0.66) / base_total)
      end
    end
  end
end
