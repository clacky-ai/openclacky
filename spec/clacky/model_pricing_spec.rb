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
        
        # Regular input (non-cached): (70,000 / 1,000,000) * $5 = $0.35
        # Output: (50,000 / 1,000,000) * $25 = $1.25
        # Cache write: (20,000 / 1,000,000) * $6.25 = $0.125
        # Cache read: (30,000 / 1,000,000) * $0.50 = $0.015
        # Total: $1.74
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.74)
        expect(result[:source]).to eq(:price)
      end
    end
    
    context "with Claude Sonnet 5" do
      let(:model) { "abs-claude-sonnet-5" }

      it "calculates cost for basic input/output (flat rate, no 200K tier)" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }

        # Input: (100,000 / 1,000,000) * $3 = $0.30
        # Output: (50,000 / 1,000,000) * $15 = $0.75
        # Total: $1.05
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.05)
        expect(result[:source]).to eq(:price)
      end

      it "uses the same flat rate above the 200K threshold (no tiering)" do
        usage = {
          prompt_tokens: 250_000,
          completion_tokens: 50_000
        }

        # Input: (250,000 / 1,000,000) * $3 = $0.75 (same rate as ≤200K)
        # Output: (50,000 / 1,000,000) * $15 = $0.75
        # Total: $1.50
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.50)
        expect(result[:source]).to eq(:price)
      end

      it "calculates cost with cache write and read" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_creation_input_tokens: 20_000,
          cache_read_input_tokens: 30_000
        }

        # Regular input (non-cached): (70,000 / 1,000,000) * $3 = $0.21
        # Output: (50,000 / 1,000,000) * $15 = $0.75
        # Cache write: (20,000 / 1,000,000) * $3.75 = $0.075
        # Cache read: (30,000 / 1,000,000) * $0.30 = $0.009
        # Total: $1.044
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.044)
        expect(result[:source]).to eq(:price)
      end

      it "does not collide with claude-sonnet-4-5 (regression guard)" do
        result = described_class.calculate_cost(model: "abs-claude-sonnet-4-5", usage: { prompt_tokens: 100_000, completion_tokens: 50_000 })
        # claude-sonnet-4.5 pricing: $3 input / $15 output — same numbers here
        # by coincidence, so assert via normalize_model_name instead to catch
        # any future accidental merge of the two pricing keys.
        expect(described_class.normalize_model_name("abs-claude-sonnet-4-5")).to eq("claude-sonnet-4.5")
        expect(described_class.normalize_model_name("abs-claude-sonnet-5")).to eq("claude-sonnet-5")
      end
    end

    context "with Claude Fable 5.1" do
      it "shares Fable 5 input/output rates but keeps its lower cache-read rate" do
        fable_5_1 = described_class.get_pricing("claude-fable-5-1")
        fable_5 = described_class.get_pricing("claude-fable-5")

        expect(fable_5_1[:input]).to eq(fable_5[:input])
        expect(fable_5_1[:output]).to eq(fable_5[:output])
        expect(fable_5_1[:cache][:write]).to eq(fable_5[:cache][:write])
        expect(fable_5_1[:cache][:read]).to eq(0.25)
        expect(fable_5[:cache][:read]).to eq(1.00)
      end
    end

    context "with Claude Opus 5" do
      let(:model) { "abs-claude-opus-5" }

      it "calculates cost for basic input/output (flat rate, no 200K tier)" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
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
          cache_creation_input_tokens: 20_000,
          cache_read_input_tokens: 30_000
        }

        # Regular input (non-cached): (70,000 / 1,000,000) * $5 = $0.35
        # Output: (50,000 / 1,000,000) * $25 = $1.25
        # Cache write: (20,000 / 1,000,000) * $6.25 = $0.125
        # Cache read: (30,000 / 1,000,000) * $0.50 = $0.015
        # Total: $1.74
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.74)
        expect(result[:source]).to eq(:price)
      end

      it "does not collide with claude-opus-4-5 (regression guard)" do
        expect(described_class.normalize_model_name("abs-claude-opus-4-8")).to eq("claude-opus-4.5")
        expect(described_class.normalize_model_name("abs-claude-opus-5")).to eq("claude-opus-5")
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
        
        # Regular input (non-cached): (70,000 / 1,000,000) * $3 = $0.21
        # Output: (50,000 / 1,000,000) * $15 = $0.75
        # Cache write (default): (20,000 / 1,000,000) * $3.75 = $0.075
        # Cache read (default): (30,000 / 1,000,000) * $0.30 = $0.009
        # Total: $1.044
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(1.044)
        expect(result[:source]).to eq(:price)
      end
      
      it "uses over_200k cache pricing for large prompts" do
        usage = {
          prompt_tokens: 250_000,
          completion_tokens: 50_000,
          cache_creation_input_tokens: 20_000,
          cache_read_input_tokens: 30_000
        }
        
        # Total input tokens: 250,000 + 20,000 = 270,000 (over threshold)
        # Regular input (non-cached): (220,000 / 1,000,000) * $6 = $1.32
        # Output: (50,000 / 1,000,000) * $22.50 = $1.125
        # Cache write (over 200k): (20,000 / 1,000,000) * $7.50 = $0.15
        # Cache read (over 200k): (30,000 / 1,000,000) * $0.60 = $0.018
        # Total: $2.613
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(2.613)
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
        
        # Regular input (non-cached): (70,000 / 1,000,000) * $1 = $0.07
        # Output: (50,000 / 1,000,000) * $5 = $0.25
        # Cache write: (20,000 / 1,000,000) * $1.25 = $0.025
        # Cache read: (30,000 / 1,000,000) * $0.10 = $0.003
        # Total: $0.348
        result = described_class.calculate_cost(model: model, usage: usage)
        expect(result[:cost]).to be_within(0.001).of(0.348)
        expect(result[:source]).to eq(:price)
      end
    end
    
    context "with DeepSeek V4 models" do
      let(:peak_time)     { Time.utc(2026, 8, 17, 2, 0, 0) }  # 02:00 UTC -> peak
      let(:off_peak_time) { Time.utc(2026, 8, 17, 5, 0, 0) }  # 05:00 UTC -> off-peak
      let(:weekend_peak_time) { Time.utc(2026, 8, 29, 2, 0, 0) } # Beijing Sat 10:00 (UTC peak window) -> off-peak
      let(:v4pro_flash_time) { Time.utc(2026, 9, 14, 6, 0, 0) } # 06:00 UTC -> after 9/14 cutover, peak
      let(:v4pro_flash_off_peak_time) { Time.utc(2026, 9, 14, 5, 0, 0) } # 05:00 UTC -> after 9/14 cutover, off-peak

      it "bills deepseek-v4-flash at peak rate" do
        usage = {
          prompt_tokens: 100_000,         # 100K tokens
          completion_tokens: 50_000        # 50K tokens
        }

        # Input: (100,000 / 1,000,000) * $0.30 = $0.03
        # Output: (50,000 / 1,000,000) * $1.20 = $0.06
        # Total: $0.09
        result = described_class.calculate_cost(model: "deepseek-v4-flash", usage: usage, now: peak_time)
        expect(result[:cost]).to be_within(0.0001).of(0.09)
        expect(result[:source]).to eq(:price)
      end

      it "bills deepseek-flash (V4.1 Flash) at peak rate" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }

        # Same rates as v4-flash:
        # Input: (100,000 / 1,000,000) * $0.30 = $0.03
        # Output: (50,000 / 1,000,000) * $1.20 = $0.06
        # Total: $0.09
        result = described_class.calculate_cost(model: "deepseek-flash", usage: usage, now: peak_time)
        expect(result[:cost]).to be_within(0.0001).of(0.09)
        expect(result[:source]).to eq(:price)
      end

      it "bills deepseek-v4-flash at off-peak rate (half of peak)" do
        usage = {
          prompt_tokens: 100_000,         # 100K tokens
          completion_tokens: 50_000        # 50K tokens
        }

        # Input: (100,000 / 1,000,000) * $0.15 = $0.015
        # Output: (50,000 / 1,000,000) * $0.60 = $0.03
        # Total: $0.045
        result = described_class.calculate_cost(model: "deepseek-v4-flash", usage: usage, now: off_peak_time)
        expect(result[:cost]).to be_within(0.0001).of(0.045)
        expect(result[:source]).to eq(:price)
      end

      it "bills deepseek-v4-flash at off-peak rate on a weekend during peak hours" do
        usage = {
          prompt_tokens: 100_000,         # 100K tokens
          completion_tokens: 50_000        # 50K tokens
        }

        # Beijing Sat 10:00 (02:00 UTC) falls inside the peak window, but
        # weekends are billed entirely at off-peak rates.
        # Input: (100,000 / 1,000,000) * $0.15 = $0.015
        # Output: (50,000 / 1,000,000) * $0.60 = $0.03
        # Total: $0.045
        result = described_class.calculate_cost(model: "deepseek-v4-flash", usage: usage, now: weekend_peak_time)
        expect(result[:cost]).to be_within(0.0001).of(0.045)
        expect(result[:source]).to eq(:price)
      end

      it "bills deepseek-v4-pro with cache at off-peak rate on a weekend" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_read_input_tokens: 30_000
        }

        # Beijing Sat 10:00 (UTC peak window) -> off-peak rates (pre-9/14 old rate).
        # Regular input: ((100_000 - 30_000) / 1_000_000) * $0.66   = $0.0462
        # Output:        (50_000 / 1_000_000)             * $1.98   = $0.099
        # Cache read:    (30_000 / 1_000_000)             * $0.022  = $0.00066
        # Total: $0.14586
        result = described_class.calculate_cost(model: "deepseek-v4-pro", usage: usage, now: weekend_peak_time)
        expect(result[:cost]).to be_within(0.0001).of(0.14586)
        expect(result[:source]).to eq(:price)
      end

      it "bills deepseek-v4-pro with cache at peak rate" do
        usage = {
          prompt_tokens: 100_000,          # includes cache reads per OpenAI-style counting
          completion_tokens: 50_000,
          cache_read_input_tokens: 30_000  # cache hit portion
        }

        # Regular input (non-cached): ((100_000 - 30_000) / 1_000_000) * $1.32   = $0.0924
        # Output:                     (50_000 / 1_000_000)             * $3.96   = $0.198
        # Cache read:                 (30_000 / 1_000_000)             * $0.044  = $0.00132
        # Total: $0.29172
        result = described_class.calculate_cost(model: "deepseek-v4-pro", usage: usage, now: peak_time)
        expect(result[:cost]).to be_within(0.0001).of(0.29172)
        expect(result[:source]).to eq(:price)
      end

      it "bills deepseek-v4-pro at flash rates after the 9/14 cutover (peak)" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_read_input_tokens: 30_000
        }

        # After 2026-09-14 v4-pro is routed to V4.1 Flash and billed at flash rates.
        # Regular input: ((100_000 - 30_000) / 1_000_000) * $0.30  = $0.021
        # Output:        (50_000 / 1_000_000)             * $1.20  = $0.06
        # Cache read:    (30_000 / 1_000_000)             * $0.006 = $0.00018
        # Total: $0.08118
        result = described_class.calculate_cost(model: "deepseek-v4-pro", usage: usage, now: v4pro_flash_time)
        expect(result[:cost]).to be_within(0.0001).of(0.08118)
        expect(result[:source]).to eq(:price)
      end

      it "bills deepseek-v4-pro at flash rates after the 9/14 cutover (off-peak)" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_read_input_tokens: 30_000
        }

        # Regular input: ((100_000 - 30_000) / 1_000_000) * $0.15  = $0.0105
        # Output:        (50_000 / 1_000_000)             * $0.60  = $0.03
        # Cache read:    (30_000 / 1_000_000)             * $0.003 = $0.00009
        # Total: $0.04059
        result = described_class.calculate_cost(model: "deepseek-v4-pro", usage: usage, now: v4pro_flash_off_peak_time)
        expect(result[:cost]).to be_within(0.0001).of(0.04059)
        expect(result[:source]).to eq(:price)
      end

      it "maps legacy deepseek-chat alias to flash peak pricing" do
        usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
        result = described_class.calculate_cost(model: "deepseek-chat", usage: usage, now: peak_time)
        expect(result[:cost]).to be_within(0.0001).of(0.09)
        expect(result[:source]).to eq(:price)
      end

      it "maps legacy deepseek-reasoner alias to flash peak pricing" do
        usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
        result = described_class.calculate_cost(model: "deepseek-reasoner", usage: usage, now: peak_time)
        expect(result[:cost]).to be_within(0.0001).of(0.09)
        expect(result[:source]).to eq(:price)
      end

      it "bills deepseek-v4-flash-vision-exp at v4-flash rates" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }

        # Same rates as v4-flash (peak):
        # Input: (100,000 / 1,000,000) * $0.30 = $0.03
        # Output: (50,000 / 1,000,000) * $1.20 = $0.06
        # Total: $0.09
        result = described_class.calculate_cost(model: "deepseek-v4-flash-vision-exp", usage: usage, now: peak_time)
        expect(result[:cost]).to be_within(0.0001).of(0.09)
        expect(result[:source]).to eq(:price)
      end

      it "normalizes deepseek-v4-flash-vision-exp to its own row (not v4-flash)" do
        expect(described_class.normalize_model_name("deepseek-v4-flash-vision-exp")).to eq("deepseek-v4-flash-vision-exp")
        expect(described_class.normalize_model_name("deepseek-v4-flash")).to eq("deepseek-v4-flash")
        expect(described_class.normalize_model_name("deepseek-flash")).to eq("deepseek-flash")
      end
    end

    context "with Kimi K2 multimodal models" do
      it "calculates kimi-k2.5 basic cost" do
        usage = {
          prompt_tokens: 100_000,          # 100K tokens
          completion_tokens: 50_000         # 50K tokens
        }

        # Input:  (100_000 / 1_000_000) * $0.60 = $0.060
        # Output: (50_000  / 1_000_000) * $3.00 = $0.150
        # Total:  $0.210
        result = described_class.calculate_cost(model: "kimi-k2.5", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(0.210)
        expect(result[:source]).to eq(:price)
      end

      it "calculates kimi-k2.6 with cache read (cache hit billing)" do
        usage = {
          prompt_tokens: 100_000,          # includes cache reads per OpenAI-style counting
          completion_tokens: 50_000,
          cache_read_input_tokens: 30_000  # cache hit portion
        }

        # Regular input (non-cached): ((100_000 - 30_000) / 1_000_000) * $0.95 = $0.0665
        # Output:                     (50_000 / 1_000_000)             * $4.00 = $0.200
        # Cache read:                 (30_000 / 1_000_000)             * $0.16 = $0.0048
        # Total: $0.2713
        result = described_class.calculate_cost(model: "kimi-k2.6", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(0.2713)
        expect(result[:source]).to eq(:price)
      end

      it "calculates kimi-k3 basic cost" do
        usage = {
          prompt_tokens: 100_000,          # 100K tokens
          completion_tokens: 50_000         # 50K tokens
        }

        # Input:  (100_000 / 1_000_000) * $3.00 = $0.300
        # Output: (50_000  / 1_000_000) * $15.00 = $0.750
        # Total:  $1.050
        result = described_class.calculate_cost(model: "kimi-k3", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(1.050)
        expect(result[:source]).to eq(:price)
      end

      it "matches kimi-k2.5 case-insensitively" do
        usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
        result = described_class.calculate_cost(model: "Kimi-K2.5", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(0.210)
        expect(result[:source]).to eq(:price)
      end

      it "does not match unregistered k2 text-only variants" do
        # K2 text-only models (kimi-k2-0905-preview, kimi-k2-thinking, etc.)
        # are not in the pricing table yet — they must return N/A, not
        # accidentally bill at k2.5/k2.6 rates via a loose regex.
        usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
        %w[kimi-k2-0905-preview kimi-k2-thinking kimi-k2-turbo-preview].each do |model|
          result = described_class.calculate_cost(model: model, usage: usage)
          expect(result[:cost]).to be_nil
          expect(result[:source]).to be_nil
        end
      end
    end

    context "with Xiaomi MiMo models" do
      it "calculates mimo-v2.5-pro basic cost" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }

        # Input:  (100_000 / 1_000_000) * $0.435 = $0.0435
        # Output: (50_000  / 1_000_000) * $0.87  = $0.0435
        # Total:  $0.0870
        result = described_class.calculate_cost(model: "mimo-v2.5-pro", usage: usage)
        expect(result[:cost]).to be_within(0.00001).of(0.087)
        expect(result[:source]).to eq(:price)
      end

      it "calculates mimo-v2.5 with cache hit at $0.0028/MTok" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_read_input_tokens: 30_000
        }

        # Regular input: ((100_000 - 30_000) / 1_000_000) * $0.14   = $0.0098
        # Output:        (50_000 / 1_000_000)             * $0.28   = $0.014
        # Cache read:    (30_000 / 1_000_000)             * $0.0028 = $0.000084
        # Total: $0.023884
        result = described_class.calculate_cost(model: "mimo-v2.5", usage: usage)
        expect(result[:cost]).to be_within(0.00001).of(0.023884)
        expect(result[:source]).to eq(:price)
      end

      it "bills mimo-v2-pro at the same rate as mimo-v2.5-pro (forwarded post 2026-06-01)" do
        usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
        v2pro    = described_class.calculate_cost(model: "mimo-v2-pro",   usage: usage)
        v25pro   = described_class.calculate_cost(model: "mimo-v2.5-pro", usage: usage)
        expect(v2pro[:cost]).to eq(v25pro[:cost])
      end

      it "bills mimo-v2-omni at the same rate as mimo-v2.5 (forwarded post 2026-06-01)" do
        usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
        omni = described_class.calculate_cost(model: "mimo-v2-omni", usage: usage)
        v25  = described_class.calculate_cost(model: "mimo-v2.5",    usage: usage)
        expect(omni[:cost]).to eq(v25[:cost])
      end

      it "calculates mimo-v2-flash at its distinct rate" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000,
          cache_read_input_tokens: 30_000
        }

        # Regular input: ((100_000 - 30_000) / 1_000_000) * $0.10 = $0.007
        # Output:        (50_000 / 1_000_000)             * $0.30 = $0.015
        # Cache read:    (30_000 / 1_000_000)             * $0.01 = $0.0003
        # Total: $0.0223
        result = described_class.calculate_cost(model: "mimo-v2-flash", usage: usage)
        expect(result[:cost]).to be_within(0.00001).of(0.0223)
        expect(result[:source]).to eq(:price)
      end

      it "matches MiMo model names case-insensitively" do
        usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
        result = described_class.calculate_cost(model: "MiMo-V2.5-Pro", usage: usage)
        expect(result[:cost]).to be_within(0.00001).of(0.087)
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
    
    context "with GPT-5.6 models (Sol / Terra / Luna)" do
      it "bills gpt-5.6-luna at tiered rates (long tier above 200K)" do
        usage = { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }

        # Input:  1M * $0.40 = $0.40
        # Output: 1M * $1.80 = $1.80
        # Total: $2.20
        result = described_class.calculate_cost(model: "gpt-5.6-luna", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(2.20)
        expect(result[:source]).to eq(:price)
      end

      it "bills gpt-5.6-terra at tiered rates (long tier above 200K)" do
        usage = { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }

        # $4.00 + $18.00 = $22.00
        result = described_class.calculate_cost(model: "gpt-5.6-terra", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(22.00)
        expect(result[:source]).to eq(:price)
      end

      it "bills gpt-5.6-sol at tiered rates with cache read" do
        usage = {
          prompt_tokens: 1_000_000,
          completion_tokens: 0,
          cache_read_input_tokens: 200_000
        }

        # Regular input: (1_000_000 - 200_000)/1M * $8.00 = $6.40
        # Cache read:     200_000 / 1M * $0.80            = $0.16
        # Total: $6.56
        result = described_class.calculate_cost(model: "gpt-5.6-sol", usage: usage)
        expect(result[:cost]).to be_within(0.0001).of(6.56)
        expect(result[:source]).to eq(:price)
      end

      it "resolves the openai/ OpenRouter prefix" do
        result = described_class.calculate_cost(
          model: "openai/gpt-5.6-luna",
          usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
        )
        # 1M > 200K -> long tier input $0.40
        expect(result[:cost]).to be_within(0.0001).of(0.40)
        expect(result[:source]).to eq(:price)
      end

      it "bills *-pro variants at the base-tier rate (identical pricing)" do
        usage = { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
        base = described_class.calculate_cost(model: "gpt-5.6-sol", usage: usage)
        pro  = described_class.calculate_cost(model: "openai/gpt-5.6-sol-pro", usage: usage)
        expect(pro[:cost]).to eq(base[:cost])
        expect(pro[:source]).to eq(:price)
      end

      it "bumps to the long tier above 200K input tokens" do
        small = described_class.calculate_cost(
          model: "gpt-5.6-terra", usage: { prompt_tokens: 100_000, completion_tokens: 0 }
        )[:cost]
        large = described_class.calculate_cost(
          model: "gpt-5.6-terra", usage: { prompt_tokens: 250_000, completion_tokens: 0 }
        )[:cost]

        # Short tier: 100K * $2.00 = $0.20; long tier: 250K * $4.00 = $1.00
        expect(small).to be_within(0.0001).of(0.20)
        expect(large).to be_within(0.0001).of(1.00)
      end

      it "returns nil for :batch ids (half-price billing not modeled)" do
        result = described_class.calculate_cost(
          model: "openai/gpt-5.6-luna:batch",
          usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
        )
        expect(result[:cost]).to be_nil
        expect(result[:source]).to be_nil
      end
    end

    context "with unknown model" do
      it "returns nil cost (no default fallback)" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        result = described_class.calculate_cost(model: "unknown-model", usage: usage)
        expect(result[:cost]).to be_nil
        expect(result[:source]).to be_nil
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
    
    context "with AWS Bedrock model names" do
      it "recognizes bedrock claude-sonnet-4-5 with dash separator" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        model = "bedrock/jp.anthropic.claude-sonnet-4-5-20250929-v1:0:region/ap-northeast-1"
        result = described_class.calculate_cost(model: model, usage: usage)
        # Should use claude-sonnet-4.5 pricing: $3/MTok input, $15/MTok output
        # Input: (100,000 / 1,000,000) * $3 = $0.30
        # Output: (50,000 / 1,000,000) * $15 = $0.75
        # Total: $1.05
        expect(result[:cost]).to be_within(0.001).of(1.05)
        expect(result[:source]).to eq(:price)
      end
      
      it "recognizes bedrock claude-opus-4-5 format" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        model = "bedrock/us.anthropic.claude-opus-4-5-20250101-v1:0"
        result = described_class.calculate_cost(model: model, usage: usage)
        # Should use claude-opus-4.5 pricing
        expect(result[:cost]).to be_within(0.001).of(1.75)
        expect(result[:source]).to eq(:price)
      end
      
      it "recognizes bedrock claude-haiku-4-5 format" do
        usage = {
          prompt_tokens: 100_000,
          completion_tokens: 50_000
        }
        
        model = "bedrock/eu.anthropic.claude-haiku-4-5-20250101-v1:0"
        result = described_class.calculate_cost(model: model, usage: usage)
        # Should use claude-haiku-4.5 pricing
        expect(result[:cost]).to be_within(0.001).of(0.35)
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
    
    it "returns nil for unknown models" do
      pricing = described_class.get_pricing("gpt-4")
      expect(pricing).to be_nil
    end
    
    it "returns nil for nil model" do
      pricing = described_class.get_pricing(nil)
      expect(pricing).to be_nil
    end
  end

  # GLM (Zhipu / Z.ai) pricing — always bill at Z.ai international flat rate,
  # regardless of mainland-vs-intl endpoint. Flat-rate (no tiered billing).
  # Source: https://docs.z.ai/guides/overview/pricing
  describe "GLM pricing" do
    it "bills glm-5.3-flashx at its list rate" do
      usage = { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
      result = described_class.calculate_cost(model: "glm-5.3-flashx", usage: usage)
      expect(result[:cost]).to be_within(0.0001).of(1.62)
      expect(result[:source]).to eq(:price)
    end

    it "bills glm-5.3-flash at its lower list rate (launch promo ignored)" do
      usage = { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
      result = described_class.calculate_cost(model: "glm-5.3-flash", usage: usage)
      # (1M/1M)*$0.15 + (1M/1M)*$0.50 = $0.65
      expect(result[:cost]).to be_within(0.0001).of(0.65)
      expect(result[:source]).to eq(:price)
    end

    it "bills glm-5.3 at the GLM-5.2 flat rate (same base model, no separate Z.ai row yet)" do
      usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
      result = described_class.calculate_cost(model: "glm-5.3", usage: usage)
      # (100_000/1M)*$1.4 + (50_000/1M)*$4.4 = 0.14 + 0.22 = $0.36
      expect(result[:cost]).to be_within(0.0001).of(0.36)
      expect(result[:source]).to eq(:price)
    end

    it "bills glm-5.2 at the Z.ai flat rate (same tier as glm-5.1)" do
      usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
      result = described_class.calculate_cost(model: "glm-5.2", usage: usage)
      # (100_000/1M)*$1.4 + (50_000/1M)*$4.4 = 0.14 + 0.22 = $0.36
      expect(result[:cost]).to be_within(0.0001).of(0.36)
      expect(result[:source]).to eq(:price)
    end

    it "bills glm-5.1 at the Z.ai flat rate" do
      usage = { prompt_tokens: 100_000, completion_tokens: 50_000 }
      result = described_class.calculate_cost(model: "glm-5.1", usage: usage)
      # (100_000/1M)*$1.4 + (50_000/1M)*$4.4 = 0.14 + 0.22 = $0.36
      expect(result[:cost]).to be_within(0.0001).of(0.36)
      expect(result[:source]).to eq(:price)
    end

    it "bills glm-5 at the Z.ai flat rate" do
      usage = { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
      result = described_class.calculate_cost(model: "glm-5", usage: usage)
      # $1 + $3.2 = $4.20
      expect(result[:cost]).to be_within(0.0001).of(4.20)
    end

    it "bills glm-5-turbo separately from glm-5v-turbo (they share rates but not row)" do
      usage = { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
      text_cost   = described_class.calculate_cost(model: "glm-5-turbo", usage: usage)[:cost]
      vision_cost = described_class.calculate_cost(model: "glm-5v-turbo", usage: usage)[:cost]
      # GLM-5-Turbo and GLM-5V-Turbo happen to share the same input/output rate
      # on Z.ai's pricing page, but they are distinct rows — they must both
      # resolve to :price (not N/A) and produce the same cost.
      expect(text_cost).to   be_within(0.0001).of(5.20)  # $1.2 + $4 = $5.2
      expect(vision_cost).to be_within(0.0001).of(5.20)
    end

    it "bills glm-4.7 at its lower flat rate" do
      usage = { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
      result = described_class.calculate_cost(model: "glm-4.7", usage: usage)
      # $0.6 + $2.2 = $2.80
      expect(result[:cost]).to be_within(0.0001).of(2.80)
    end

    it "does NOT apply tiered pricing for prompts over 200K (GLM is flat-rate)" do
      small = described_class.calculate_cost(
        model: "glm-5.1",
        usage: { prompt_tokens: 10_000, completion_tokens: 0 }
      )[:cost]
      large = described_class.calculate_cost(
        model: "glm-5.1",
        usage: { prompt_tokens: 250_000, completion_tokens: 0 }
      )[:cost]
      # Per-token rate must be identical — rules out accidental tiered cost.
      expect(small / 10_000).to be_within(0.0000001).of(large / 250_000)
    end

    it "bills cache reads at $0.26/MTok and cache writes at the input miss rate for glm-5.1" do
      usage = {
        prompt_tokens: 100_000,
        completion_tokens: 0,
        cache_read_input_tokens: 50_000,
        cache_creation_input_tokens: 50_000
      }
      result = described_class.calculate_cost(model: "glm-5.1", usage: usage)
      # Regular input: (100_000 - 50_000) / 1M * $1.4  = $0.07
      # Cache read:     50_000 / 1M * $0.26            = $0.013
      # Cache write:    50_000 / 1M * $1.40 (miss rate)= $0.07
      # Total: $0.153
      expect(result[:cost]).to be_within(0.0001).of(0.153)
    end

    it "is case-insensitive for GLM model names" do
      result = described_class.calculate_cost(
        model: "GLM-5.1",
        usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
      )
      expect(result[:cost]).to be_within(0.0001).of(1.40)
      expect(result[:source]).to eq(:price)
    end
  end

  describe "Volcengine Ark pricing" do
    it "bills doubao-seed-2.0-mini at the mapped CNY tiers" do
      default = described_class.calculate_cost(
        model: "doubao-seed-2.0-mini",
        usage: { prompt_tokens: 100_000, completion_tokens: 50_000 }
      )
      over_200k = described_class.calculate_cost(
        model: "doubao-seed-2.0-mini",
        usage: { prompt_tokens: 250_000, completion_tokens: 50_000 }
      )

      expect(default[:cost]).to be_within(0.0001).of(0.036)
      expect(default[:source]).to eq(:price)
      expect(over_200k[:cost]).to be_within(0.0001).of(0.0895)
      expect(over_200k[:source]).to eq(:price)
    end

    it "keeps subscription-only kimi-k2.8-preview pricing unknown" do
      result = described_class.calculate_cost(
        model: "kimi-k2.8-preview",
        usage: { prompt_tokens: 100_000, completion_tokens: 50_000 }
      )

      expect(result[:cost]).to be_nil
      expect(result[:source]).to be_nil
    end
  end

  # MiniMax pricing — identical across the international (.io) and mainland
  # China (.com) endpoints per the team's verification.
  # Source: https://platform.minimax.io/docs/api-reference/api-overview
  # (Pay-as-You-Go)
  describe "MiniMax pricing" do
    it "bills MiniMax-M2.5 at its list price" do
      # MiniMax-M2.5 is still listed on https://www.minimax.io/models/text
      # and available via the API (MiniMax-M2.5 and MiniMax-M2.5-highspeed).
      result = described_class.calculate_cost(
        model: "MiniMax-M2.5",
        usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
      )
      expect(result[:cost]).to be_within(0.01).of(0.30)
    end

    it "bills MiniMax-M2.7 with its higher cache-read rate" do
      usage = {
        prompt_tokens: 1_000_000,
        completion_tokens: 1_000_000,
        cache_read_input_tokens: 500_000
      }
      result = described_class.calculate_cost(model: "MiniMax-M2.7", usage: usage)
      # Regular input: 500_000 / 1M * $0.30 = $0.15
      # Cache read:    500_000 / 1M * $0.06 = $0.03
      # Output:      1_000_000 / 1M * $1.20 = $1.20
      # Total: $1.38
      expect(result[:cost]).to be_within(0.0001).of(1.38)
    end

    it "handles the capitalised MiniMax- prefix from providers.rb" do
      # providers.rb uses "MiniMax-M2.7" (capitalised), but the pricing table
      # key is lowercase — normalize_model_name must bridge the two.
      result = described_class.calculate_cost(
        model: "MiniMax-M2.7",
        usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
      )
      expect(result[:cost]).to be_within(0.0001).of(0.30)
      expect(result[:source]).to eq(:price)
    end

    it "is also case-insensitive (lowercased input works)" do
      result = described_class.calculate_cost(
        model: "minimax-m2.7",
        usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
      )
      expect(result[:source]).to eq(:price)
    end

    it "bills MiniMax-M3 at its flat ≤512K-tier rate" do
      usage = {
        prompt_tokens: 100_000,
        completion_tokens: 50_000,
        cache_read_input_tokens: 20_000
      }
      result = described_class.calculate_cost(model: "MiniMax-M3", usage: usage)
      # Regular input: (100_000 - 20_000) / 1M * $0.60 = $0.048
      # Cache read:     20_000 / 1M * $0.12            = $0.0024
      # Output:         50_000 / 1M * $2.40            = $0.12
      # Total: $0.1704
      expect(result[:cost]).to be_within(0.0001).of(0.1704)
      expect(result[:source]).to eq(:price)
    end

    it "keeps MiniMax-M3 flat above 200K (no tier bump)" do
      # Records only the ≤512K tier; the global 200K threshold must NOT
      # escalate it (would over-charge the 200K–512K band).
      result = described_class.calculate_cost(
        model: "MiniMax-M3",
        usage: { prompt_tokens: 400_000, completion_tokens: 0 }
      )
      # 400_000 / 1M * $0.60 = $0.24 (flat, not the 512K–1M $1.20 rate)
      expect(result[:cost]).to be_within(0.0001).of(0.24)
    end
  end

  # Qwen (Alibaba DashScope) pricing - international list price (promo discounts
  # are intentionally ignored for cost estimation). cache.write/read map to the
  # official explicit-cache create/hit prices.
  describe "Qwen pricing" do
    it "bills qwen3.6-plus at official list prices" do
      usage = {
        prompt_tokens: 1_000_000,
        completion_tokens: 1_000_000,
        cache_read_input_tokens: 200_000
      }
      result = described_class.calculate_cost(model: "qwen3.6-plus", usage: usage)
      # Regular input: (1_000_000 - 200_000)/1M * $0.50 = $0.40
      # Cache read:     200_000 / 1M * $0.05            = $0.01
      # Output:       1_000_000 / 1M * $3.00            = $3.00
      # Total: $3.41
      expect(result[:cost]).to be_within(0.0001).of(3.41)
      expect(result[:source]).to eq(:price)
    end

    it "bills qwen3.8-max at the same flat list rate as qwen3.7-max" do
      result = described_class.calculate_cost(
        model: "qwen3.8-max",
        usage: { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
      )
      # input 1M * $2.5 + output 1M * $7.5 = $10.00 (flat, no tier bump)
      expect(result[:cost]).to be_within(0.0001).of(10.00)
      expect(result[:source]).to eq(:price)
    end

    it "bills qwen3.7-max at the flat list rate, not tiered" do
      result = described_class.calculate_cost(
        model: "qwen3.7-max",
        usage: { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
      )
      # input 1M * $2.5 + output 1M * $7.5 = $10.00 (flat, no tier bump)
      expect(result[:cost]).to be_within(0.0001).of(10.00)
    end

    it "bills qwen3.7-plus explicit cache create/hit at list rates" do
      usage = {
        prompt_tokens: 100_000,
        completion_tokens: 0,
        cache_creation_input_tokens: 100_000,
        cache_read_input_tokens: 50_000
      }
      result = described_class.calculate_cost(model: "qwen3.7-plus", usage: usage)
      # Regular input: (100_000 - 50_000)/1M * $0.4  = $0.020
      # Cache write:    100_000 / 1M * $0.5          = $0.050
      # Cache read:      50_000 / 1M * $0.04         = $0.002
      # Total: $0.072
      expect(result[:cost]).to be_within(0.0001).of(0.072)
    end

    it "falls back to input rate for models without explicit-cache pricing" do
      usage = {
        prompt_tokens: 100_000,
        completion_tokens: 0,
        cache_read_input_tokens: 50_000
      }
      result = described_class.calculate_cost(model: "qwen3.6-27b", usage: usage)
      # Regular input: (100_000 - 50_000)/1M * $0.60 = $0.030
      # Cache read:     50_000 / 1M * $0.60 (=input)  = $0.030
      # Total: $0.060
      expect(result[:cost]).to be_within(0.0001).of(0.060)
    end

    it "maps qwen3-vl-plus (renamed from qwen-vl-plus)" do
      result = described_class.calculate_cost(
        model: "qwen3-vl-plus",
        usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
      )
      expect(result[:cost]).to be_within(0.0001).of(0.60)
      expect(result[:source]).to eq(:price)
    end

    it "returns N/A for retired Qwen models (qwen3.7-flash, qwen-vl-plus, qwen-vl-max)" do
      %w[qwen3.7-flash qwen-vl-plus qwen-vl-max].each do |m|
        result = described_class.calculate_cost(
          model: m,
          usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
        )
        expect(result[:cost]).to be_nil,   "expected N/A for #{m}, got #{result[:cost]}"
        expect(result[:source]).to be_nil, "expected nil source for #{m}"
      end
    end
  end

  describe "Gemini 3.6 Flash pricing" do
    it "bills at flat Vertex AI rates" do
      usage = {
        prompt_tokens: 1_000_000,
        completion_tokens: 1_000_000,
        cache_read_input_tokens: 200_000
      }
      result = described_class.calculate_cost(model: "or-gemini-3-6-flash", usage: usage)
      # Regular input: (1_000_000 - 200_000)/1M * $1.50 = $1.20
      # Cache read:     200_000 / 1M * $0.15            = $0.03
      # Output:       1_000_000 / 1M * $7.50            = $7.50
      # Total: $8.73
      expect(result[:cost]).to be_within(0.0001).of(8.73)
      expect(result[:source]).to eq(:price)
    end

    it "normalizes bare upstream id gemini-3.6-flash" do
      expect(described_class.normalize_model_name("gemini-3.6-flash")).to eq("gemini-3.6-flash")
    end
  end

  describe "Gemini 3.7 Flash pricing" do
    it "normalizes platform alias or-gemini-3-7-flash" do
      expect(described_class.normalize_model_name("or-gemini-3-7-flash")).to eq("gemini-3.7-flash")
    end

    it "normalizes bare upstream id gemini-3.7-flash" do
      expect(described_class.normalize_model_name("gemini-3.7-flash")).to eq("gemini-3.7-flash")
    end
  end

  describe "Gemini 3.8 Flash pricing" do
    it "normalizes platform alias or-gemini-3-8-flash" do
      expect(described_class.normalize_model_name("or-gemini-3-8-flash")).to eq("gemini-3.8-flash")
    end

    it "normalizes bare upstream id gemini-3.8-flash" do
      expect(described_class.normalize_model_name("gemini-3.8-flash")).to eq("gemini-3.8-flash")
    end
  end

  # Guards against accidentally billing unrelated model names at a
  # neighbouring model's rate — the anchored ^...$ regex in normalize_model_name
  # should reject fuzzy matches and fall through to nil (cost=N/A).
  describe "strict matching for GLM/MiniMax" do
    it "returns nil cost for unregistered GLM variants" do
      %w[glm-4.7-flash glm-4.6 glm-4.5-air glm-ocr glm-4.6v].each do |m|
        result = described_class.calculate_cost(
          model: m,
          usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
        )
        expect(result[:cost]).to be_nil,   "expected N/A for #{m}, got #{result[:cost]}"
        expect(result[:source]).to be_nil, "expected nil source for #{m}, got #{result[:source]}"
      end
    end

    it "returns nil cost for unregistered MiniMax variants" do
      %w[m2-her minimax-abab6].each do |m|
        result = described_class.calculate_cost(
          model: m,
          usage: { prompt_tokens: 1_000_000, completion_tokens: 0 }
        )
        expect(result[:cost]).to be_nil,   "expected N/A for #{m}, got #{result[:cost]}"
        expect(result[:source]).to be_nil, "expected nil source for #{m}, got #{result[:source]}"
      end
    end
  end
end
