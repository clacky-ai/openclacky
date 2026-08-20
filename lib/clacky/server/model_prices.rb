# frozen_string_literal: true

module Clacky
  module Server
    # GET /api/model_prices?models=a,b,c
    # Resolves each model's input/output price (USD per 1M tokens) from
    # Clacky::ModelPricing plus a cost ratio vs the baseline model, so the
    # web UI never hardcodes prices - updating PRICING_TABLE is enough.
    module ModelPrices
      BASELINE_MODEL = "claude-sonnet-5"

      def self.build(models_query, now: Time.now)
        names = (models_query || "").split(",").map(&:strip).reject(&:empty?)

        baseline = Clacky::ModelPricing.get_pricing(BASELINE_MODEL)
        base_total = baseline[:input][:default] + baseline[:output][:default]

        prices = {}
        names.each do |name|
          pricing = Clacky::ModelPricing.get_pricing(name)
          pricing = Clacky::ModelPricing.resolve_deepseek_tier(pricing, now) if pricing && pricing[:deepseek]
          next unless pricing
          pin  = pricing[:input][:default]
          pout = pricing[:output][:default]
          prices[name] = { in: pin, out: pout, ratio: (pin + pout) / base_total }
        end

        {
          baseline: {
            model: BASELINE_MODEL,
            in: baseline[:input][:default],
            out: baseline[:output][:default]
          },
          prices: prices
        }
      end
    end
  end
end
