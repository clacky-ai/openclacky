# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ReasoningLevels do
  def openai_fields(model, level)
    body = {}
    Clacky::MessageFormat::OpenAI.apply_reasoning_params(body, model, level)
    body.slice(:thinking, :output_config, :reasoning_effort, :reasoning)
  end

  def anthropic_fields(model, level)
    body = Clacky::MessageFormat::Anthropic.build_request_body(
      [], model, [], 1024, false, reasoning_effort: level
    )
    body.slice(:thinking, :output_config, :reasoning_effort, :reasoning)
  end

  FAMILY_SAMPLES = {
    "GLM-5.3"            => %w[low high max],
    "GLM-4.6"            => %w[off high max],
    "kimi-k3"            => %w[low high max],
    "minimax-m3.1-flash" => %w[low medium high xhigh max],
    "minimax-m3"         => %w[off medium],
    "mimo-v2"            => %w[off medium],
    "deepseek-v4.1-flash" => %w[off low medium high max],
    "or-gemini-4-argon"  => %w[low medium high],
    "or-gemini-4-hydrogen" => %w[low medium high xhigh],
    "abs-claude-sonnet-4-6" => Clacky::ReasoningLevels::ALL
  }.freeze

  describe ".for_model" do
    FAMILY_SAMPLES.each do |model, expected|
      it "returns #{expected.inspect} for #{model}" do
        expect(described_class.for_model(model)).to eq(expected)
      end
    end

    it "is case insensitive" do
      expect(described_class.for_model("MiniMax-M3")).to eq(%w[off medium])
    end

    it "falls back to every stop for an unknown model" do
      expect(described_class.for_model("some-new-model")).to eq(Clacky::ReasoningLevels::ALL)
    end

    it "treats a nil model as the generic family" do
      expect(described_class.for_model(nil)).to eq(Clacky::ReasoningLevels::ALL)
    end

    it "keeps the narrower GLM-5.3 entry ahead of the GLM-4/5 entry" do
      expect(described_class.for_model("glm-5.3")).to eq(%w[low high max])
    end
  end

  # The table is only honest while every advertised stop really reaches the
  # provider as a different request. Adapters own the encoding, so they are what
  # this checks against - on both transports a model can run through.
  describe "adapter agreement" do
    FAMILY_SAMPLES.each do |model, levels|
      %i[openai_fields anthropic_fields].each do |transport|
        it "keeps #{model} stops distinct on #{transport}" do
          bodies = levels.map { |l| send(transport, model, l) }
          expect(bodies.uniq.size).to eq(levels.size)
        end
      end
    end

    it "collapses exactly the stops the table drops" do
      # medium is indistinguishable from low on GLM-5.3, which is why the table
      # omits it - a regression here means the table starts lying.
      expect(openai_fields("GLM-5.3", "medium")).to eq(openai_fields("GLM-5.3", "low"))
      expect(openai_fields("minimax-m3", "high")).to eq(openai_fields("minimax-m3", "low"))
    end

    it "keeps an unexpressible Gemini 4 level inside the model's ladder" do
      expect(openai_fields("or-gemini-4-argon", "max")).to eq(openai_fields("or-gemini-4-argon", "high"))
      expect(openai_fields("or-gemini-4-argon", "xhigh")).to eq(openai_fields("or-gemini-4-argon", "high"))
      expect(openai_fields("or-gemini-4-argon", "off")).to eq(openai_fields("or-gemini-4-argon", "low"))
      expect(openai_fields("or-gemini-4-hydrogen", "max")).to eq(openai_fields("or-gemini-4-hydrogen", "xhigh"))
      expect(openai_fields("or-gemini-4-hydrogen", "off")).to eq(openai_fields("or-gemini-4-hydrogen", "low"))
    end
  end

  describe ".clamp" do
    it "keeps a supported level untouched" do
      expect(described_class.clamp("GLM-5.3", "max")).to eq("max")
    end

    it "snaps an unsupported level to the nearest stop, preferring the cheaper one on a tie" do
      expect(described_class.clamp("GLM-5.3", "medium")).to eq("low")
      expect(described_class.clamp("GLM-5.3", "xhigh")).to eq("high")
    end

    it "leaves a never-chosen level alone so the provider default still applies" do
      expect(described_class.clamp("GLM-5.3", "")).to be_nil
      expect(described_class.clamp("GLM-5.3", nil)).to be_nil
    end

    it "snaps a binary model onto one of its two stops" do
      expect(described_class.clamp("minimax-m3", "max")).to eq("medium")
      expect(described_class.clamp("minimax-m3", "off")).to eq("off")
    end

    it "drops the stops Gemini 4 cannot express" do
      expect(described_class.clamp("or-gemini-4-argon", "max")).to eq("high")
      expect(described_class.clamp("or-gemini-4-argon", "off")).to eq("low")
      expect(described_class.clamp("or-gemini-4-hydrogen", "max")).to eq("xhigh")
      expect(described_class.clamp("or-gemini-4-hydrogen", "xhigh")).to eq("xhigh")
    end

    it "returns nil when the model has no reasoning control" do
      allow(described_class).to receive(:for_model).and_return([])
      expect(described_class.clamp("whatever", "high")).to be_nil
    end
  end
end
