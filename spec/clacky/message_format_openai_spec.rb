# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::MessageFormat::OpenAI do
  describe ".build_request_body" do
    let(:model) { "deepseek-v4-pro" }
    let(:tools) { [] }
    let(:max_tokens) { 1024 }

    it "passes through plain text messages unchanged" do
      messages = [
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Hi there!" }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      expect(body[:messages]).to eq(messages)
    end

    it "passes through text-only content arrays unchanged" do
      messages = [
        { role: "user", content: [{ type: "text", text: "Hello" }] }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      expect(body[:messages]).to eq(messages)
    end

    it "keeps image_url blocks when vision_supported is true (default)" do
      messages = [
        { role: "user", content: [
          { type: "text", text: "Look at this:" },
          { type: "image_url", image_url: { url: "data:image/png;base64,abc123" } }
        ] }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      expect(body[:messages].first[:content].length).to eq(2)
      expect(body[:messages].first[:content][1][:type]).to eq("image_url")
    end

    it "converts image_url blocks to text placeholders when vision_supported is false" do
      messages = [
        { role: "user", content: [
          { type: "text", text: "Look at this:" },
          { type: "image_url", image_url: { url: "data:image/png;base64,abc123" } }
        ] }
      ]

      body = described_class.build_request_body(
        messages, model, tools, max_tokens, false,
        vision_supported: false
      )
      result_content = body[:messages].first[:content]
      # Both blocks remain: the original text + image_url replaced with text placeholder
      expect(result_content.length).to eq(2)
      expect(result_content[0][:type]).to eq("text")
      expect(result_content[0][:text]).to eq("Look at this:")
      expect(result_content[1][:type]).to eq("text")
      expect(result_content[1][:text]).to include("Image content removed")
    end

    it "replaces a sole image_url block with a placeholder text when vision_supported is false" do
      messages = [
        { role: "user", content: [
          { type: "image_url", image_url: { url: "data:image/png;base64,abc123" } }
        ] }
      ]

      body = described_class.build_request_body(
        messages, model, tools, max_tokens, false,
        vision_supported: false
      )
      result_content = body[:messages].first[:content]
      expect(result_content.length).to eq(1)
      expect(result_content.first[:type]).to eq("text")
      expect(result_content.first[:text]).to include("Image content removed")
    end

    it "drops empty text blocks during conversion" do
      messages = [
        { role: "user", content: [
          { type: "text", text: "" },
          { type: "text", text: "Valid text" }
        ] }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      result_content = body[:messages].first[:content]
      expect(result_content.length).to eq(1)
      expect(result_content.first[:text]).to eq("Valid text")
    end

    it "preserves cache_control on text blocks" do
      messages = [
        { role: "user", content: [
          { type: "text", text: "Cached text", cache_control: { type: "ephemeral" } }
        ] }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      result_content = body[:messages].first[:content]
      expect(result_content.first[:cache_control]).to eq({ type: "ephemeral" })
    end

    it "handles messages with String content (no conversion needed)" do
      messages = [
        { role: "user", content: "Plain string content" },
        { role: "assistant", content: "Another string" }
      ]

      body = described_class.build_request_body(
        messages, model, tools, max_tokens, false,
        vision_supported: false
      )
      expect(body[:messages].first[:content]).to eq("Plain string content")
      expect(body[:messages].last[:content]).to eq("Another string")
    end

    it "preserves non-content message fields" do
      messages = [
        { role: "user", content: "Hello", task_id: 5, system_injected: true }
      ]

      body = described_class.build_request_body(messages, model, tools, max_tokens, false)
      expect(body[:messages].first[:task_id]).to eq(5)
      expect(body[:messages].first[:system_injected]).to eq(true)
    end

    it "handles mixed content with multiple image_url blocks when vision_supported is false" do
      messages = [
        { role: "user", content: [
          { type: "image_url", image_url: { url: "data:image/png;base64,img1" } },
          { type: "text", text: "Between images" },
          { type: "image_url", image_url: { url: "data:image/png;base64,img2" } }
        ] }
      ]

      body = described_class.build_request_body(
        messages, model, tools, max_tokens, false,
        vision_supported: false
      )
      result_content = body[:messages].first[:content]
      # All 3 blocks remain, but image_url blocks become text placeholders
      expect(result_content.length).to eq(3)
      expect(result_content[0][:text]).to include("Image content removed")
      expect(result_content[1][:text]).to eq("Between images")
      expect(result_content[2][:text]).to include("Image content removed")
    end
  end

  describe ".build_request_body reasoning_effort mapping" do
    let(:messages) { [{ role: "user", content: "Hi" }] }
    let(:tools) { [] }
    let(:max_tokens) { 1024 }

    context "for GLM models" do
      let(:model) { "glm-5.2" }

      it "maps 'high' to thinking enabled + reasoning_effort high" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "high"
        )
        expect(body[:thinking]).to eq({ type: "enabled" })
        expect(body[:reasoning_effort]).to eq("high")
      end

      it "maps 'max' to thinking enabled + reasoning_effort max" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "max"
        )
        expect(body[:thinking]).to eq({ type: "enabled" })
        expect(body[:reasoning_effort]).to eq("max")
      end

      it "collapses 'medium' to thinking enabled + reasoning_effort high" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "medium"
        )
        expect(body[:thinking]).to eq({ type: "enabled" })
        expect(body[:reasoning_effort]).to eq("high")
      end

      it "maps 'off' to thinking disabled without reasoning_effort" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "off"
        )
        expect(body[:thinking]).to eq({ type: "disabled" })
        expect(body).not_to have_key(:reasoning_effort)
      end

      it "maps 'none' to thinking disabled without reasoning_effort" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "none"
        )
        expect(body[:thinking]).to eq({ type: "disabled" })
        expect(body).not_to have_key(:reasoning_effort)
      end

      it "maps 'minimal' to thinking disabled without reasoning_effort" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "minimal"
        )
        expect(body[:thinking]).to eq({ type: "disabled" })
        expect(body).not_to have_key(:reasoning_effort)
      end

      it "matches namespaced GLM ids used by OpenRouter / proxy gateways" do
        %w[zhipu/glm-5.2 openrouter/zhipu/glm-5].each do |namespaced|
          body = described_class.build_request_body(
            messages, namespaced, tools, max_tokens, false, reasoning_effort: "max"
          )
          expect(body[:thinking]).to eq({ type: "enabled" })
          expect(body[:reasoning_effort]).to eq("max")
        end
      end

      it "does not match non-GLM ids that merely contain the substring" do
        body = described_class.build_request_body(
          messages, "myglm-5-custom", tools, max_tokens, false, reasoning_effort: "high"
        )
        expect(body).not_to have_key(:thinking)
        expect(body[:reasoning_effort]).to eq("high")
      end

      it "adds no thinking or reasoning_effort when reasoning_effort is nil" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: nil
        )
        expect(body).not_to have_key(:thinking)
        expect(body).not_to have_key(:reasoning_effort)
      end
    end

    context "for Kimi K3 models" do
      let(:model) { "kimi-k3" }

      it "maps 'high' to reasoning_effort high" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "high"
        )
        expect(body[:reasoning_effort]).to eq("high")
        expect(body).not_to have_key(:thinking)
      end

      it "maps 'max' to reasoning_effort max" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "max"
        )
        expect(body[:reasoning_effort]).to eq("max")
      end

      it "maps 'off' to reasoning_effort low (cannot disable thinking)" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "off"
        )
        expect(body[:reasoning_effort]).to eq("low")
      end

      it "adds no reasoning_effort when reasoning_effort is nil" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: nil
        )
        expect(body).not_to have_key(:reasoning_effort)
        expect(body).not_to have_key(:thinking)
      end
    end

    context "for MiMo-V2.5 models" do
      let(:model) { "mimo-v2.5-pro" }

      it "uses max_completion_tokens instead of max_tokens" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false
        )
        expect(body[:max_completion_tokens]).to eq(max_tokens)
        expect(body).not_to have_key(:max_tokens)
      end

      it "maps reasoning_effort to thinking enabled" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "high"
        )
        expect(body[:thinking]).to eq({ type: "enabled" })
        expect(body).not_to have_key(:reasoning_effort)
      end

      it "maps reasoning_effort 'off' to thinking disabled" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "off"
        )
        expect(body[:thinking]).to eq({ type: "disabled" })
      end

      it "omits thinking when reasoning_effort is nil" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: nil
        )
        expect(body).not_to have_key(:thinking)
        expect(body).not_to have_key(:reasoning_effort)
      end

      it "works with the omni-modal variant mimo-v2.5" do
        body = described_class.build_request_body(
          messages, "mimo-v2.5", tools, max_tokens, false, reasoning_effort: "medium"
        )
        expect(body[:thinking]).to eq({ type: "enabled" })
        expect(body[:max_completion_tokens]).to eq(max_tokens)
      end
    end

    context "for generic OpenAI-compatible models" do
      let(:model) { "deepseek-v4-pro" }

      it "uses max_tokens (not max_completion_tokens)" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false
        )
        expect(body[:max_tokens]).to eq(max_tokens)
        expect(body).not_to have_key(:max_completion_tokens)
      end


      it "passes reasoning_effort through unchanged" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: "high"
        )
        expect(body[:reasoning_effort]).to eq("high")
        expect(body).not_to have_key(:thinking)
      end

      it "adds no reasoning_effort when nil" do
        body = described_class.build_request_body(
          messages, model, tools, max_tokens, false, reasoning_effort: nil
        )
        expect(body).not_to have_key(:reasoning_effort)
      end
    end
  end

  describe ".normalize_block" do
    it "returns nil for empty text blocks" do
      result = described_class.normalize_block(
        { type: "text", text: "" },
        vision_supported: true
      )
      expect(result).to be_nil
    end

    it "returns nil for nil text blocks" do
      result = described_class.normalize_block(
        { type: "text", text: nil },
        vision_supported: true
      )
      expect(result).to be_nil
    end

    it "passes through unknown block types" do
      result = described_class.normalize_block(
        { type: "custom_type", data: "something" },
        vision_supported: true
      )
      expect(result).to eq({ type: "custom_type", data: "something" })
    end

    it "passes through non-hash blocks" do
      result = described_class.normalize_block("plain string", vision_supported: true)
      expect(result).to eq("plain string")
    end
  end
end
