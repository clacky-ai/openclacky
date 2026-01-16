# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ModelPricing do
  describe ".calculate_cost" do
    context "with Claude Opus 4.5" do
      let(:model) { "claude-opus-4.5" }
      
      it "calculates cost for basic input/output" do
        usage = {
          prompt_tokens: 100_000,        # 100K tokens
          completion_tokens: 50_000       # 50K tokens
        }
        
        # Input: (100,000 / 1,000,000) * $5 = $0.50
        # Output: (50,000 / 1,000,000) * $25 = $1.25
        # Total: $1.75
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.75)
        expect(result[:source]).to eq(:price)
      end
      
      it "calculates cost with cache write and read" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_creation_input_tokens: 20_000,  # Cache write
          cache_read_input_tokens: 30_000       # Cache read
        }
        
        # Regular input: (50,000 / 1,000,000) * $5 = $0.25
        # Output: (50,000 / 1,000,000) * $25 = $1.25
        # Cache write: (20,000 / 1,000,000) * $6.25 = $0.125
        # Cache read: (30,000 / 1,000,000) * $0.50 = $0.015
        # Total: $1.64
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.64)
        expect(result[:source]).to eq(:price)
      end
    end
    
    context "with Claude Sonnet 4.5" do
      let(:model) { "claude-sonnet-4.5" }
      
      it "uses default pricing for prompts ≤ 200K tokens" do
        usage = {
          prompt_tokens: 100_000,        # 100K tokens (under threshold)
          completion_tokens: 50_000
        }
        
        # Input: (100,000 / 1,000,000) * $3 = $0.30
        # Output: (50,000 / 1,000,000) * $15 = $0.75
        # Total: $1.05
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.05)
        expect(result[:source]).to eq(:price)
      end
      
      it "uses over_200k pricing for large prompts" do
        usage = {
          prompt_tokens: 250_000,        # 250K tokens (over threshold)
          completion_tokens: 50_000
        }
        
        # Input: (250,000 / 1,000,000) * $6 = $1.50
        # Output: (50,000 / 1,000,000) * $22.50 = $1.125
        # Total: $2.625
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(2.625)
        expect(result[:source]).to eq(:price)
      end
      
      it "uses tiered cache pricing" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_creation_input_tokens: 20_000,
          cache_read_input_tokens: 30_000
        }
        
        # Regular input: (50,000 / 1,000,000) * $3 = $0.15
        # Output: (50,000 / 1,000,000) * $15 = $0.75
        # Cache write (default): (20,000 / 1,000,000) * $3.75 = $0.075
        # Cache read (default): (30,000 / 1,000,000) * $0.30 = $0.009
        # Total: $0.984
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(0.984)
        expect(result[:source]).to eq(:price)
      end
      
      it "uses over_200k cache pricing for large prompts" do
        usage = {
          prompt_tokens: 250_000,
          completion_tokens: 50_000,
          cache_creation_input_tokens: 20_000,
          cache_read_input_tokens: 30_000
        }
        
        # Total input tokens: 250,000 + 20,000 + 30,000 = 300,000 (over threshold)
        # Regular input: (200,000 / 1,000,000) * $6 = $1.20
        # Output: (50,000 / 1,000,000) * $22.50 = $1.125
        # Cache write (over 200k): (20,000 / 1,000,000) * $7.50 = $0.15
        # Cache read (over 200k): (30,000 / 1,000,000) * $0.60 = $0.018
        # Total: $2.493
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(2.493)
        expect(result[:source]).to eq(:price)
      end
    end
    
    context "with Claude Haiku 4.5" do
      let(:model) { "claude-haiku-4.5" }
      
      it "calculates cost correctly" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        # Input: (100,000 / 1,000,000) * $1 = $0.10
        # Output: (50,000 / 1,000,000) * $5 = $0.25
        # Total: $0.35
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(0.35)
        expect(result[:source]).to eq(:price)
      end
      
      it "calculates cache costs" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_creation_input_tokens: 20_000,
          cache_read_input_tokens: 30_000
        }
        
        # Regular input: (50,000 / 1,000,000) * $1 = $0.05
        # Output: (50,000 / 1,000,000) * $5 = $0.25
        # Cache write: (20,000 / 1,000,000) * $1.25 = $0.025
        # Cache read: (30,000 / 1,000,000) * $0.10 = $0.003
        # Total: $0.328
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(0.328)
        expect(result[:source]).to eq(:price)
      end
    end
    
    context "with Claude 3.5 models" do
      it "supports claude-3-5-sonnet-20241022" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        result = described_class.calculate_cost(model: "claude-3-5-sonnet-20241022", usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.05)
        expect(result[:source]).to eq(:price)
      end
      
      it "supports claude-3-5-haiku-20241022" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        result = described_class.calculate_cost(model: "claude-3-5-haiku-20241022", usage: usage)
        expect(result[:cost]).to be_within(0.001).of(0.35)
        expect(result[:source]).to eq(:price)
      end
    end
    
    context "with unknown model" do
      it "uses default fallback pricing" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        # Default pricing: input=$0.50, output=$1.50
        # Input: (100,000 / 1,000,000) * $0.50 = $0.05
        # Output: (50,000 / 1,000,000) * $1.50 = $0.075
        # Total: $0.125
        result = described_class.calculate_cost(model: "unknown-model", usage: usage)
        expect(result[:cost]).to be_within(0.001).of(0.125)
        expect(result[:source]).to eq(:default)
      end
    end
    
    context "with case variations" do
      it "normalizes model names (uppercase)" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        result = described_class.calculate_cost(model: "CLAUDE-OPUS-4.5", usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.75)
        expect(result[:source]).to eq(:price)
      end
      
      it "normalizes model names (with spaces)" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        result = described_class.calculate_cost(model: "claude opus 4.5", usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.75)
        expect(result[:source]).to eq(:price)
      end
    end
  end
  
  describe ".get_pricing" do
    it "returns pricing for known models" do
      pricing = described_class.get_pricing("claude-opus-4.5")
      expect(pricing[:input][:default]).to eq(5.00)
      expect(pricing[:output][:default]).to eq(25.00)
    end
    
    it "returns default pricing for unknown models" do
      pricing = described_class.get_pricing("gpt-4")
      expect(pricing[:input][:default]).to eq(0.50)
      expect(pricing[:output][:default]).to eq(1.50)
    end
    
    it "returns default pricing for nil model" do
      pricing = described_class.get_pricing(nil)
      expect(pricing[:input][:default]).to eq(0.50)
      expect(pricing[:output][:default]).to eq(1.50)
    end
  end
end
