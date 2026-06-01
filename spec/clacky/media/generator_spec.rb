# frozen_string_literal: true

require "spec_helper"
require "clacky/agent_config"
require "clacky/media/generator"

RSpec.describe Clacky::Media::Generator do
  describe "#generate_image" do
    context "when no type=image model is configured" do
      it "returns a not_configured error response" do
        config = Clacky::AgentConfig.new(models: [
          { "model" => "some-chat-model", "type" => "default",
            "base_url" => "https://example.invalid/v1", "api_key" => "k" }
        ])
        result = described_class.new(config).generate_image(prompt: "a cat")

        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("not_configured")
        expect(result["error"]).to include("type=image")
      end
    end

    context "when image model is configured" do
      it "delegates to OpenAICompat with the correct entry" do
        image_entry = {
          "model"    => "or-gpt-image-1",
          "type"     => "image",
          "base_url" => "https://api.openclacky.com",
          "api_key"  => "clacky-test"
        }
        config = Clacky::AgentConfig.new(models: [image_entry])

        fake_provider = instance_double(Clacky::Media::OpenAICompat)
        expect(Clacky::Media::OpenAICompat).to receive(:new) do |entry|
          expect(entry["model"]).to eq("or-gpt-image-1")
          expect(entry["type"]).to eq("image")
          fake_provider
        end
        expect(fake_provider).to receive(:generate_image).with(
          prompt: "a cat", aspect_ratio: "square", output_dir: "/tmp/work"
        ).and_return({ "success" => true, "image" => "/tmp/work/assets/generated/img.png" })

        result = described_class.new(config).generate_image(
          prompt: "a cat", aspect_ratio: "square", output_dir: "/tmp/work"
        )
        expect(result["success"]).to be true
      end
    end
  end
end
