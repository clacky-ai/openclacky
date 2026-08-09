# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::MessageFormat::Anthropic do
  describe ".parse_response usage normalisation" do
    def parse(usage)
      described_class.parse_response(
        "content" => [{ "type" => "text", "text" => "hi" }],
        "stop_reason" => "end_turn",
        "usage" => usage
      )[:usage]
    end

    context "when the upstream uses Anthropic native semantics" do
      it "adds cache_read to the post-breakpoint input tail" do
        usage = parse(
          "input_tokens" => 658,
          "cache_read_input_tokens" => 36_164,
          "cache_creation_input_tokens" => 656,
          "output_tokens" => 700
        )

        expect(usage[:prompt_tokens]).to eq(36_822)
        expect(usage[:completion_tokens]).to eq(700)
        expect(usage[:cache_read_input_tokens]).to eq(36_164)
        expect(usage[:cache_creation_input_tokens]).to eq(656)
        expect(usage[:total_tokens]).to eq(658 + 656 + 700)
      end

      it "leaves uncached responses untouched" do
        usage = parse("input_tokens" => 1_200, "output_tokens" => 300)

        expect(usage[:prompt_tokens]).to eq(1_200)
        expect(usage[:total_tokens]).to eq(1_500)
        expect(usage).not_to have_key(:cache_read_input_tokens)
      end
    end

    context "when a gateway reports input_tokens OpenAI-style" do
      it "does not double count the cached prefix" do
        usage = parse(
          "input_tokens" => 36_822,
          "cache_read_input_tokens" => 36_164,
          "cache_creation_input_tokens" => 656,
          "output_tokens" => 700
        )

        expect(usage[:prompt_tokens]).to eq(36_166)
        expect(usage[:total_tokens]).to eq(2 + 656 + 700)
      end

      it "keeps the billable non-cached input small" do
        usage = parse(
          "input_tokens" => 60_627,
          "cache_read_input_tokens" => 60_476,
          "cache_creation_input_tokens" => 149,
          "output_tokens" => 120
        )

        expect(usage[:prompt_tokens] - usage[:cache_read_input_tokens]).to eq(2)
      end

      it "reads input_tokens as the full input once the cache buckets fit inside it" do
        usage = parse(
          "input_tokens" => 100,
          "cache_read_input_tokens" => 50,
          "output_tokens" => 7
        )

        expect(usage[:prompt_tokens]).to eq(100)
      end
    end

    it "prices a cached turn from the normalised gateway usage" do
      usage = parse(
        "input_tokens" => 36_822,
        "cache_read_input_tokens" => 36_164,
        "cache_creation_input_tokens" => 656,
        "output_tokens" => 700
      )
      result = Clacky::ModelPricing.calculate_cost(
        model: "claude-opus-5", usage: usage
      )

      expected = (2 * 5.0 + 656 * 6.25 + 36_164 * 0.5 + 700 * 25.0) / 1_000_000.0
      expect(result[:cost]).to be_within(1e-9).of(expected)
    end
  end
end
