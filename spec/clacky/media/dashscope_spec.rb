# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "clacky/media/dashscope"

RSpec.describe Clacky::Media::DashScope do
  let(:entry) do
    {
      "model"    => "qwen-image-2.0-pro",
      "base_url" => "https://dashscope.aliyuncs.com/compatible-mode/v1",
      "api_key"  => "sk-test-key"
    }
  end
  let(:provider) { described_class.new(entry) }

  let(:captured) { {} }
  let(:fake_conn) { instance_double(Faraday::Connection) }
  let(:fake_response) { instance_double(Faraday::Response, success?: true, status: 200, body: response_body) }

  before do
    allow(provider).to receive(:connection).and_return(fake_conn)
    allow(fake_conn).to receive(:post) do |path, &blk|
      captured[:path] = path
      req = double("req")
      allow(req).to receive(:headers).and_return({})
      allow(req).to receive(:body=) { |b| captured[:body] = b }
      blk.call(req)
      fake_response
    end
    # avoid real network for the URL download step
    allow(provider).to receive(:download_url).and_return("PNG_BYTES")
  end

  describe "#generate_image" do
    let(:response_body) do
      JSON.generate({
        "output" => {
          "choices" => [
            { "finish_reason" => "stop",
              "message" => { "role" => "assistant",
                             "content" => [{ "image" => "https://oss.example.com/x.png?Expires=1" }] } }
          ]
        },
        "usage"      => { "width" => 2048, "height" => 2048, "image_count" => 1 },
        "request_id" => "req-123"
      })
    end

    it "posts the DashScope generation envelope and saves the downloaded image" do
      Dir.mktmpdir do |tmp|
        result = provider.generate_image(prompt: "a cute cat", aspect_ratio: "square", output_dir: tmp)

        # endpoint path (host is handled by Faraday base url)
        expect(captured[:path]).to eq("/api/v1/services/aigc/multimodal-generation/generation")

        # request envelope
        sent = JSON.parse(captured[:body])
        expect(sent["model"]).to eq("qwen-image-2.0-pro")
        expect(sent.dig("input", "messages", 0, "role")).to eq("user")
        expect(sent.dig("input", "messages", 0, "content", 0, "text")).to eq("a cute cat")
        expect(sent.dig("parameters", "size")).to eq("2048*2048")
        expect(sent.dig("parameters", "n")).to eq(1)
        expect(sent.dig("parameters", "prompt_extend")).to be true
        expect(sent.dig("parameters", "watermark")).to be false

        # response
        expect(result["success"]).to be true
        expect(result["image"]).to start_with(File.join(tmp, "assets", "generated"))
        expect(File.binread(result["image"])).to eq("PNG_BYTES")
        expect(result["provider"]).to eq("qwen")
        expect(result["model"]).to eq("qwen-image-2.0-pro")
        expect(result["size"]).to eq("2048*2048")
        expect(result["request_id"]).to eq("req-123")
      end
    end

    it "maps landscape/portrait to qwen-image-2.0 recommended sizes" do
      Dir.mktmpdir do |tmp|
        expect(provider.generate_image(prompt: "x", aspect_ratio: "landscape", output_dir: tmp)["size"]).to eq("2688*1536")
        expect(provider.generate_image(prompt: "x", aspect_ratio: "portrait", output_dir: tmp)["size"]).to eq("1536*2688")
      end
    end

    it "uses the fixed resolution set for qwen-image-max models" do
      max_provider = described_class.new(entry.merge("model" => "qwen-image-max"))
      allow(max_provider).to receive(:connection).and_return(fake_conn)
      allow(max_provider).to receive(:download_url).and_return("PNG_BYTES")
      Dir.mktmpdir do |tmp|
        result = max_provider.generate_image(prompt: "x", aspect_ratio: "landscape", output_dir: tmp)
        expect(result["size"]).to eq("1664*928")
        expect(JSON.parse(captured[:body]).dig("parameters", "size")).to eq("1664*928")
      end
    end

    it "defaults to landscape for an unknown aspect_ratio" do
      Dir.mktmpdir do |tmp|
        result = provider.generate_image(prompt: "x", aspect_ratio: "panoramic", output_dir: tmp)
        expect(result["aspect_ratio"]).to eq("landscape")
      end
    end
  end

  describe "validation" do
    let(:response_body) { "{}" }

    it "rejects an empty prompt without calling upstream" do
      expect(fake_conn).not_to receive(:post)
      result = provider.generate_image(prompt: "   ", output_dir: Dir.pwd)
      expect(result["success"]).to be false
      expect(result["error_type"]).to eq("invalid_argument")
    end

    it "rejects a missing api_key without calling upstream" do
      no_key = described_class.new(entry.merge("api_key" => ""))
      allow(no_key).to receive(:connection).and_return(fake_conn)
      expect(fake_conn).not_to receive(:post)
      result = no_key.generate_image(prompt: "x", output_dir: Dir.pwd)
      expect(result["success"]).to be false
      expect(result["error_type"]).to eq("auth_required")
    end
  end

  describe "error handling" do
    context "with a DashScope business error payload" do
      let(:response_body) { JSON.generate({ "code" => "InvalidParameter", "message" => "num_images_per_prompt must be 1", "request_id" => "r1" }) }

      it "surfaces code and message as an api_error" do
        result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("api_error")
        expect(result["error"]).to include("InvalidParameter")
        expect(result["error"]).to include("num_images_per_prompt")
      end
    end

    context "with an empty choices payload" do
      let(:response_body) { JSON.generate({ "output" => { "choices" => [] } }) }

      it "returns empty_response" do
        result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("empty_response")
      end
    end

    context "when the image download fails" do
      let(:response_body) do
        JSON.generate({ "output" => { "choices" => [{ "message" => { "content" => [{ "image" => "https://oss.example.com/x.png" }] } }] } })
      end

      it "returns download_failed" do
        allow(provider).to receive(:download_url).and_return(nil)
        result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("download_failed")
      end
    end

    context "with invalid JSON" do
      let(:response_body) { "<html>500</html>" }

      it "returns invalid_response" do
        result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("invalid_response")
      end
    end
  end

  describe "#endpoint_base" do
    it "derives scheme+host, discarding the pasted compatible-mode path" do
      expect(provider.send(:endpoint_base)).to eq("https://dashscope.aliyuncs.com")
    end

    it "handles the intl host" do
      p = described_class.new(entry.merge("base_url" => "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"))
      expect(p.send(:endpoint_base)).to eq("https://dashscope-intl.aliyuncs.com")
    end
  end
end
