# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "base64"
require "clacky/media/openai_compat"

RSpec.describe Clacky::Media::OpenAICompat, "#generate_video" do
  let(:entry) do
    {
      "model"    => "or-veo-3-1",
      "base_url" => "https://api.openclacky.com",
      "api_key"  => "clacky-test-key"
    }
  end
  let(:provider) { described_class.new(entry) }

  let(:fake_conn) { instance_double(Faraday::Connection) }
  let(:fake_response) { instance_double(Faraday::Response, success?: success, status: status, body: response_body) }
  let(:success) { true }
  let(:status) { 200 }

  before do
    allow(provider).to receive(:video_connection).and_return(fake_conn)
    allow(fake_conn).to receive(:post).and_yield(double("req").tap do |r|
      allow(r).to receive(:headers).and_return({})
      allow(r).to receive(:body=)
    end).and_return(fake_response)
  end

  context "with a base64 video payload" do
    let(:b64) { Base64.strict_encode64("MP4_BYTES") }
    let(:response_body) do
      JSON.generate({
        "data"     => [{ "b64_json" => b64, "mime_type" => "video/mp4" }],
        "usage"    => { "duration_seconds" => 8 },
        "cost_usd" => 2.688
      })
    end

    it "saves the mp4 under assets/generated and returns success" do
      Dir.mktmpdir do |tmp|
        result = provider.generate_video(prompt: "a drone shot over mountains", output_dir: tmp)

        expect(result["success"]).to be true
        expect(result["video"]).to start_with(File.join(tmp, "assets", "generated"))
        expect(result["video"]).to end_with(".mp4")
        expect(File.binread(result["video"])).to eq("MP4_BYTES")
        expect(result["duration_seconds"]).to eq(8)
        expect(result["cost_usd"]).to eq(2.688)
        expect(result["provider"]).to eq("openclacky")
        expect(result["model"]).to eq("or-veo-3-1")
      end
    end

    it "defaults aspect to landscape and duration to 8" do
      Dir.mktmpdir do |tmp|
        result = provider.generate_video(prompt: "x", output_dir: tmp)
        expect(result["aspect_ratio"]).to eq("landscape")
        expect(result["duration_seconds"]).to eq(8)
      end
    end

    it "passes a first-frame image through when given" do
      expect(fake_conn).to receive(:post) do |&blk|
        req = double("req", headers: {})
        captured = nil
        allow(req).to receive(:body=) { |b| captured = b }
        blk.call(req)
        payload = JSON.parse(captured)
        expect(payload["image"]).to eq({ "b64_json" => "IMG", "mime_type" => "image/png" })
        fake_response
      end
      Dir.mktmpdir do |tmp|
        provider.generate_video(
          prompt: "extend this", output_dir: tmp,
          image: { "b64_json" => "IMG", "mime_type" => "image/png" }
        )
      end
    end
  end

  context "validation and errors" do
    let(:response_body) { "{}" }

    it "rejects an empty prompt" do
      result = provider.generate_video(prompt: "   ")
      expect(result["success"]).to be false
      expect(result["error_type"]).to eq("invalid_argument")
    end

    it "returns auth_required when api_key is blank" do
      provider = described_class.new(entry.merge("api_key" => ""))
      allow(provider).to receive(:video_connection).and_return(fake_conn)
      result = provider.generate_video(prompt: "x")
      expect(result["success"]).to be false
      expect(result["error_type"]).to eq("auth_required")
    end

    context "when upstream returns non-2xx" do
      let(:success) { false }
      let(:status) { 502 }
      let(:response_body) { "upstream boom" }

      it "surfaces an api_error" do
        result = provider.generate_video(prompt: "x")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("api_error")
        expect(result["error"]).to include("502")
      end
    end

    context "when upstream returns no video" do
      let(:response_body) { JSON.generate({ "data" => [] }) }

      it "returns empty_response" do
        result = provider.generate_video(prompt: "x")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("empty_response")
      end
    end
  end
end
